# Data Model: Arch Linux ARM (RPi 3 Model B v1.2) Cross-Compilation Build Flow

**Date**: 2026-08-07
**Feature**: 027-arch-arm-rpi3-build

The "data model" for this build feature is the set of artifacts the build produces and consumes, and their lifecycle.

## Entities

### 1. Build container

| Field | Value |
|-------|-------|
| Base image | `archlinux:latest` (NOT archlinux:armv7 — we cross FROM x86_64) |
| Lifecycle | ephemeral — one container per build; never persisted |
| Mounts | `/src` (read-only, source tree), `/build` (writable, copy of /src), `/out` (writable, output directory) |
| Entrypoint | `makepkg -s` (FR-013) — invokes `pacman -S --asdeps ${makedepends}` inside, then runs the build |
| Size estimates | ~600 MB after toolchain install |

### 2. PKGBUILD

| Field | Value |
|-------|-------|
| Path | `docker/pkgbuilds/mtls-hello.PKGBUILD` (template copied into `$pkgdir` for each build) |
| Lifecycle | static template + per-build substitution of `${version}` from `dub.json` |
| Sections | `pkgname`, `pkgver`, `pkgrel=1`, `arch=('armv7h')`, `depends=()`, `makedepends=()`, `optdepends=()`, `pkgdesc`, `url`, `license`, `source=()` (none — uses mounted /src), `build=()`, `package=()` |
| Replaces | (none) |

### 3. `.PKGINFO`

| Field | Value |
|-------|-------|
| Path | inside pkgroot, written by makepkg from PKGBUILD |
| Key-value pairs | `pkgname = mtls-hello`, `pkgver = X.Y.Z-1`, `pkgdesc = ...`, `arch = armv7h`, `builddate = $(SOURCE_DATE_EPOCH)`, `packager = ...`, `size = XXXXX` (kilobytes of the payload), `depend = apache`, `depend = bash`, ... |
| Mandatory | pkgname, pkgver, arch, depend (per FR-006) |
| Validation | `pacman -Qi` or `tar -xOf .pkg.tar.zst .PKGINFO` must succeed |

### 4. `.INSTALL`

| Field | Value |
|-------|-------|
| Path | inside pkgroot, along with `.PKGINFO` |
| Functions | `post_install()`, `post_upgrade()` — print informational message, no real work |
| Mandatory in payload | yes (Arch conventions), but empty functions are acceptable |

### 5. Build volume mounts

| Mount | Type | Purpose |
|-------|------|---------|
| `/src` | read-only source tree (volume) | what the host passes in |
| `/build` | writable inside container | where header files are generated, where the LDC object files land |
| `/out` | writable (mapped to host volume) | where the emitted `.pkg.tar.zst` lands for the host to consume |
| `/var/cache/pacman/pkg` (optional) | writable, persistent across builds | speed up re-runs (cache of downloaded `.pkg.tar.*` files) |

### 6. Cross-compilation env vars (set in container before `makepkg`)

| Var | Value | Effect |
|-----|-------|--------|
| `LD_FLAGS` | `-target=armv7-unknown-linux-gnueabihf` (passed to dub via `dub --target=armv7-unknown-linux-gnueabihf`) | LDC emits armv7-hard-float object code |
| `CARGO_TARGET_*` | not used (no Rust code) | n/a |
| `GOARCH` | `arm` | Go compiles for ARM |
| `GOARM` | `7` | Go picks VFPv3 + NEON instructions |
| `CGO_ENABLED` | `0` | NNCP is pure-Go; disabling CGO avoids cross-CC dependency |
| `CC` / `CXX` | `arm-linux-gnueabihf-gcc` / `arm-linux-gnueabihf-g++` | (used only for sparse native compile steps, e.g., version.sh generation) |
| `PKGEXT` | `.pkg.tar.zst` | (Arch's default, but explicit for clarity) |
| `SRCPKGDEST` | `/out` | where makepkg drops the package |
| `SOURCE_DATE_EPOCH` | derived from git HEAD commit time | reproducibility |

### 7. Build-time and runtime dependencies (declared in PKGBUILD)

#### `makedepends` (build-time, installed by `makepkg -s`)

```text
arm-linux-gnueabihf-gcc
arm-linux-gnueabihf-binutils
arm-linux-gnueabihf-glibc
arm-linux-gnueabihf-linux-api-headers
ldc
dub
pkgconf
make
git
openssl
zstd
pacman  # autodependency
```

#### `depends` (runtime, resolved by `pacman -U` on the target)

```text
apache
bash
openssl
git
coreutils
grep
findutils
sed
awk
glibc
zstd
```

#### Notes
- `arm-linux-gnueabihf-glibc` provides `ld-linux-armhf.so.3` at install time on the *build* container; the runtime `glibc` on the *target* Pi 3 is what carries the binary through to execution.
- `apache` is the package providing the http daemon + mod_ssl + mod_dav + mod_cgi (Arch Linux ARM ships the prefork MPM with all of these enabled by default).

### 8. Output: PKG archive

| Field | Value |
|-------|-------|
| Filename pattern | `mtls-hello-${version}-1-armv7h.pkg.tar.zst` |
| Contents (under `./` inside the archive) | `.PKGINFO`, `.INSTALL`, `.MTREE`, `usr/bin/mtls-hello`, `var/lib/mtls-hello/handlers/*`, `var/lib/mtls-hello/scripts/*` (including `cgi-lib.sh`, `sync-lib.sh`, `on-discovery.d/`, `apache-config.sh`, `gen-certs.sh`, `build-nncp.sh`, `install.sh`, `merge-spool.sh`, `trust-host.sh`, `log-capture.sh`, `cleanup-common.sh`), `var/lib/mtls-hello/cli/*`, `var/lib/mtls-hello/bin/{nncp,nncp-toss,nncp-call,...}` (cross-compiled armv7), `var/lib/mtls-hello/drop/`, `us`r/lib/systemd/user/mtls-hello.service` |

### 9. Test target: qemu-arm chroot

| Field | Value |
|-------|-------|
| Base image (downloaded) | `archlinuxarm/armv7h/base` (from Docker Hub `archlinuxarm/`) |
| Emulator | `qemu-arm-static` registered via binfmt_misc on the host |
| Lifecycle | ephemeral — created per-CI-run, removed after |
| Purpose | Validate `pacman -U`, `mtls-hello --version` against the real ARMv7 instruction set without ARM hardware (SC-002) |
| Validation gate | `pacman -Qi mtls-hello` succeeds; `mtls-hello --version` exits 0 within 10 s (SC-003) |

### 10. CI / release-artifact surface

| Slot | Path on host |
|------|--------------|
| After `just package-arch-arm-rpi3` | `dist/mtls-hello-*-armv7h.pkg.tar.zst` (project root relative to `dub.json`) |
| CI artifact upload | the same file, picked up by `actions/upload-artifact@vN` |
| Release artifact | attached to GitHub Release on tagged commit (existing workflow) |

## State transitions

A build run cycles through these states:

```
(no state) ── justfile recipe ──→ container starts
                                    │
                                    ├── makepkg -s ──→ pacman -S --asdeps makedepends
                                    │                  │
                                    │                  ├── cross-compile LDC step
                                    │                  ├── cross-compile Go step (NNCP)
                                    │                  ├── stage install tree
                                    │                  └── package step
                                    │
                                    └── exit code 0 ──→ host collects /out file
                                                       │
                                                       ├── (optional) qemu test step
                                                       └── commit / publish
```

Validation gates (must clear):

1. After `makepkg -s` exits 0: package exists at `/out/mtls-hello-*-armv7h.pkg.tar.zst`.
2. After `tar -xOf <pkg> .PKGINFO`: `arch = armv7h` is present.
3. After install in qemu chroot: `mtls-hello --version` produces a value and exits 0.
