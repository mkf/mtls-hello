# Research: Native Distribution Packages

## Decision: System-wide install paths (/usr), user data under $HOME

**Decision**: Packages install the binary to `/usr/bin/mtls-hello`, handlers to `/usr/lib/mtls-hello/`, and the systemd unit to `/usr/lib/systemd/user/mtls-hello.service`. User-specific data (certs, repos, trust store) lives under the user's home, configured via environment variables or `--data-dir`.

**Rationale**: Native distro packages are system-wide by convention. `dpkg` and `pacman` track files under `/usr` for clean upgrades and removal. Mixing package-managed files with `~/.local` would break package-manager tracking and confuse upgrades. User data stays out of the package's file list so removal preserves it.

**Alternatives considered**:
- Install to `~/.local` like the existing `just install` — not trackable by the package manager, breaks on multi-user systems.
- Install to `/opt/mtls-hello` — non-standard, requires extra PATH/symlinks.

## Decision: Build with LDC + dub natively on each distro

**Decision**: Each build environment (native host or Docker container) installs `ldc` and `dub` from the distro's package manager and runs `dub build --compiler=ldc2`. No Guix, no cross-compilation.

**Rationale**: LDC is available in both Debian (`apt install ldc`) and Arch (`pacman -S ldc`). vibe.d's dependencies (OpenSSL, zlib) are also in both distros' repos. Building natively means the binary links against the target distro's glibc and libraries — no interpreter mismatch, no patchelf, no vendored libraries.

**Alternatives considered**:
- Cross-compile from the openSUSE host — fragile, needs matching sysroots, glibc version drift.
- Build in Guix and patchelf — reintroduces Guix, which the user explicitly rejected.
- Static linking — D/vibe.d static linking with OpenSSL is poorly supported in LDC 1.27; dynamic linking against system libs is simpler and lets the package manager handle security updates.

## Decision: Docker base images — debian:bookworm, archlinux:latest

**Decision**: The Debian container uses `debian:bookworm` (Debian 12, current stable). The Arch container uses `archlinux:latest` (official Arch image).

**Rationale**: `debian:bookworm` is the oldest still-supported stable with LDC 1.27+ and glibc 2.36 — a good baseline. `archlinux:latest` matches a rolling Arch install. Both are official Docker Hub images, widely cached, and represent real target environments.

**Alternatives considered**:
- `debian:bullseye` (Debian 11) — LDC there is 1.20, too old for vibe-d 0.10.
- `ubuntu:22.04` — works but Debian stable is the canonical Debian target; Ubuntu users can use the same .deb.
- Minimal/slim images — save space but need extra packages installed anyway; the standard images are simpler.

## Decision: Read-only source mount, toolchain baked into image

**Decision**: Dockerfiles install the build toolchain (ldc, dub, openssl-dev, pkg-config) in the image. The project source is mounted read-only at `/src` at run time. The build script runs inside the container, producing the package, which is copied to a mounted `/out` directory.

**Rationale**: Baking the toolchain into the image means image rebuilds are rare (only when the toolchain changes). Mounting the source read-only means every `just package-docker` picks up source changes instantly without rebuilding the image. This is the fastest iteration loop for the developer.

**Alternatives considered**:
- Bake source into image (`COPY . /src`) — requires image rebuild on every source change; slow iteration.
- Mount toolchain from host — reintroduces host dependency; not portable.

## Decision: postinst / .INSTALL generates the cert at install time

**Decision**: The Debian `postinst` and Arch `.INSTALL` scripts run `openssl req -x509` to generate a self-signed server certificate (CN=hostname, 10yr, key mode 0600) on first install, if none exists. On upgrade, the existing cert is preserved.

**Rationale**: The certificate is machine-specific (CN=hostname) and must be generated on the target, not at build time. This mirrors the feature 010 `install.sh` logic exactly. Using the package's post-install hook means `dpkg -i` / `pacman -U` is a single self-contained step.

**Alternatives considered**:
- Generate cert at build time — wrong hostname, breaks on every machine.
- Require the operator to run a separate cert-generation command after install — extra step, easy to forget.
- Ship a pre-generated cert — defeats the purpose of per-machine identity.

## Decision: Distro detection via /etc/os-release

**Decision**: The entry-point `package.sh` sources `/etc/os-release` and checks `ID` and `ID_LIKE` to determine the distro family. Debian/Ubuntu → Debian path; Arch → Arch path; anything else → error listing supported distros.

**Rationale**: `/etc/os-release` is the freedesktop.org standard for distro identification, present on virtually every modern Linux. `ID_LIKE` handles derivatives (Ubuntu sets `ID_LIKE=debian`).

**Alternatives considered**:
- Check for `dpkg` vs `pacman` binaries — works but less informative; doesn't distinguish Debian from other dpkg distros cleanly.
- `lsb_release` — not installed by default everywhere.
- Hardcode per-host — not portable.
