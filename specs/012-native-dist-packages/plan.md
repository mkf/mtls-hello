# Implementation Plan: Native Distribution Packages

**Branch**: `012-native-dist-packages` | **Date**: 2026-08-05 | **Spec**: [spec.md](./spec.md)

## Summary

Three ways to produce installable native packages for mtls-hello, all building from source with no Guix:

1. **Native from-scratch scripts** — run on Debian or Arch directly; build with the distro's `ldc` + `dub`, package with `dpkg-deb` / `makepkg`.
2. **Distro-detecting entry point** — one command that sniffs the host distro and dispatches to the right native script.
3. **Docker build** — runs on any host with Docker (including the openSUSE Slowroll dev machine); spins up a `debian:bookworm` container and an `archlinux:latest` container, builds the matching package inside each, copies both out.

All three paths produce byte-equivalent packages: same files, same paths, same post-install cert generation, same systemd user unit.

## Technical Context

**Language/Version**: D (LDC 1.27+ / DMD), vibe.d 0.10.x — built natively on the target distro via `dub`

**Build toolchain on target**: `ldc`, `dub`, OpenSSL dev headers, `pkg-config` — all installed from the distro's native package manager

**Packaging tools**: `dpkg-deb` (Debian), `makepkg` / `pacman` (Arch), `docker` (any host)

**Storage**: Output packages land in `dist/` (gitignored)

**Testing**: BATS — verify the entry-point script detects distro correctly; verify the Debian/Arch packaging scripts produce a well-formed package tree (control file / PKGINFO, file list, postinst/INSTALL script). Docker tests are optional/manual (require Docker daemon).

**Target Platform**: 64-bit x86 Linux — Debian 12+/Ubuntu 22.04+, Arch Linux

**Project Type**: New build/packaging scripts + Dockerfiles + justfile targets

**Constraints**: No Guix anywhere. No host toolchain required for Docker path. Docker flow must be perfectly portable.

**Scale/Scope**: ~4 new scripts, ~2 Dockerfiles, ~3 justfile recipes

## Constitution Check

Template — PASS by default.

## Project Structure

### Files added

```text
scripts/package-debian.sh          # Native Debian .deb build (runs on Debian)
scripts/package-arch.sh            # Native Arch .pkg.tar.zst build (runs on Arch)
scripts/package.sh                 # Distro-detecting entry point (US3)
scripts/package-common.sh          # Shared staging logic (build + tree layout)
docker/Dockerfile.debian           # Debian build container
docker/Dockerfile.arch             # Arch build container
docker/docker-build.sh             # Orchestrates both containers, copies output
justfile                           # +package-debian, +package-arch, +package (native)
                                   # +package-docker (Docker path, any host)
dist/                              # Output directory (gitignored)
.gitignore                         # +dist/
```

### Shared staging layout (package-common.sh)

Both packages deliver the same tree, rooted at the distro-appropriate prefix:

```
usr/bin/mtls-hello                              # compiled binary
usr/lib/mtls-hello/handlers/bundle.post.sh      # handler scripts
usr/lib/mtls-hello/scripts/on-discover.sh       # discovery callback
usr/lib/mtls-hello/scripts/pre-push.sh.new      # hook template
usr/lib/systemd/user/mtls-hello.service         # systemd user unit (system path)
```

The systemd unit uses absolute paths (`/usr/bin/mtls-hello`, `/var/lib/mtls-hello/...`) and a system-wide data dir (`/var/lib/mtls-hello`) rather than `~/.local`, because packages install system-wide. The user runs the service as their user instance; certs/repos live under `$HOME` or a per-user data dir via environment overrides. The postinst generates a self-signed cert on first install into a default location if none exists.

### Debian package (package-debian.sh)

```
mtls-hello_<version>_amd64.deb
├── DEBIAN/control          # Package metadata, Depends: libc6, libssl3, openssl
├── DEBIAN/postinst         # Generate self-signed cert if missing
├── DEBIAN/prerm            # (optional) stop service
├── usr/bin/mtls-hello
├── usr/lib/mtls-hello/...
└── usr/lib/systemd/user/mtls-hello.service
```

### Arch package (package-arch.sh)

```
mtls-hello-<version>-1-x86_64.pkg.tar.zst
├── .PKGINFO                # Package metadata, depend = openssl ldc-libs
├── .INSTALL                # Generate self-signed cert if missing
├── usr/bin/mtls-hello
├── usr/lib/mtls-hello/...
└── usr/lib/systemd/user/mtls-hello.service
```

### Docker build (docker/docker-build.sh)

```bash
# Mounts the repo read-only at /src, builds inside each container,
# copies the finished package out to dist/
docker build -t mtls-hello-build-debian -f docker/Dockerfile.debian .
docker run --rm -v "$PWD:/src:ro" -v "$PWD/dist:/out" mtls-hello-build-debian
docker build -t mtls-hello-build-arch -f docker/Dockerfile.arch .
docker run --rm -v "$PWD:/src:ro" -v "$PWD/dist:/out" mtls-hello-build-arch
```

**Dockerfile.debian**: `FROM debian:bookworm` → `apt-get install ldc dub libssl-dev pkg-config` → `COPY scripts/package-debian.sh` → build + package → `cp *.deb /out/`

**Dockerfile.arch**: `FROM archlinux:latest` → `pacman -S ldc dub openssl pkgconf` → `COPY scripts/package-arch.sh` → build + package → `cp *.pkg.tar.zst /out/`

Both Dockerfiles are self-contained: they install their own toolchain, build from the mounted source, and emit the package. No Guix, no host compilers.

## Design Decisions

### Why system-wide install paths (/usr) instead of ~/.local

Native packages install system-wide. The binary goes to `/usr/bin/mtls-hello`, handlers to `/usr/lib/mtls-hello/`, the systemd unit to `/usr/lib/systemd/user/`. This is the conventional layout for distro packages and lets `dpkg`/`pacman` track every file. User-specific data (certs, repos, trust store) stays under the user's home, set via environment variables or the data-dir flag — the package never touches user home directories.

### Why a shared package-common.sh

The staging logic (build the binary, lay out the file tree, copy handlers/scripts/unit) is identical for both distros. Only the packaging metadata format differs (DEBIAN/control vs .PKGINFO). Extracting the common part avoids drift between the two package scripts and the Docker builds (which call the same scripts).

### Why Docker mounts the source read-only

The containers build from the exact source tree the developer has checked out, without baking the source into the image. This means changing a line of D code and re-running `just package-docker` picks up the change immediately — no rebuild of the Docker image needed. The image only contains the toolchain; the source is mounted at build time.

### Why Dockerfiles install the toolchain from scratch

Each container starts from a bare base image and installs `ldc`, `dub`, OpenSSL dev headers, and packaging tools from the distro's package manager. This guarantees a clean, reproducible build environment matching the target distro, independent of the host. No Guix, no host-mounted compilers.

### Why the entry-point script sniffs /etc/os-release

`/etc/os-release` is the standard distro identification file (present on Debian, Ubuntu, Arch, Fedora, openSUSE). The entry-point script sources it and checks `ID`/`ID_LIKE` to dispatch. On unsupported distros it lists the supported ones and exits non-zero.

### Why postinst/INSTALL generates the cert, not the build

The self-signed certificate is machine-specific (CN=hostname) and must be generated on the target at install time, not at build time. The package's post-install script runs `openssl req -x509` if no cert exists yet — mirroring the feature 010 install.sh logic. On upgrade, the existing cert is preserved.

## Implementation Strategy

### MVP: Docker build (US4)

The developer's primary path. Build this first so packages can be produced on the openSUSE Slowroll dev machine immediately:

1. `package-common.sh` — shared staging
2. `package-debian.sh` + `docker/Dockerfile.debian`
3. `package-arch.sh` + `docker/Dockerfile.arch`
4. `docker/docker-build.sh` — orchestrates both
5. `just package-docker` recipe

### Then: native scripts (US1/US2)

6. `just package-debian` (calls `package-debian.sh` directly, assumes Debian host)
7. `just package-arch` (calls `package-arch.sh` directly, assumes Arch host)

### Then: distro detect (US3)

8. `scripts/package.sh` + `just package` — sniffs `/etc/os-release`, dispatches.

### Polish

9. `.gitignore` adds `dist/`
10. README "Building Packages" section
11. BATS tests for distro detection + package tree structure (run on whatever host the test suite runs on; Docker tests manual)
