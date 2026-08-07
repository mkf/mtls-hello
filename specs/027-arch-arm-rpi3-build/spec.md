# Feature Specification: Arch Linux ARM (RPi 3 Model B v1.2) Cross-Compilation Build Flow

**Feature Branch**: `027-arch-arm-rpi3-build`

**Created**: 2026-08-07

**Status**: Draft

**Input**: User description: "lets create a new flow for building a package for ArchLinuxARM Raspberry Pi 3 Model B v1.2 (thats going to be cross-compilation)"

> Note: hardware revision v1.2 of the Raspberry Pi 3 Model B identifies the BCM2837 SoC (ARMv7-A, Cortex-A53, hard-float). The target package is therefore `arch=armv7h`. The "Raspberry Pi 3 Model B+" (v1.2 board-revision ≠ Model B v1.2) is out of scope; use a separate spec if needed.

## User Scenarios & Testing *(mandatory)*

### User Story 1 — Operator deploys on Raspberry Pi 3 Model B v1.2 (Priority: P1)

An operator has a Raspberry Pi 3 Model B v1.2 running Arch Linux ARM and wants to install mtls-hello without compiling it on the Pi itself (compilation on the Pi is slow and requires installing a D toolchain). They download a pre-built package, copy it to the Pi, and install via `pacman -U mtls-hello-<version>-armv7h.pkg.tar.zst`. After installation, the daemon is ready to start.

**Why this priority**: This is the primary deliverable. Without an installable package, none of the existing mtls-hello features are usable on RPi 3 hardware.

**Independent Test**: A `.pkg.tar.zst` file is produced with `arch=armv7h` in its PKGINFO. Installing it on Arch Linux ARM (verified via qemu-arm-static + a chroot of the official archlinuxarm image OR actual hardware) succeeds; `pacman -Qi mtls-hello` shows the package; the installed `mtls-hello` binary runs successfully and reports its version.

**Acceptance Scenarios**:

1. **Given** a clean Arch Linux ARM chroot on an x86_64 host, **When** the operator runs `pacman -U /path/to/mtls-hello-<v>-armv7h.pkg.tar.zst`, **Then** the package installs without dependency errors and the binary `/usr/bin/mtls-hello` is present.
2. **Given** the package is installed on the target, **When** the operator runs `mtls-hello --version`, **Then** it prints the version and exits with status 0 within 10 seconds.
3. **Given** the package is installed on the target, **When** the operator inspects `/var/lib/mtls-hello/` or runs `pacman -Ql mtls-hello`, **Then** it lists the install layout matching the existing data-dir conventions (`handlers/`, `scripts/cgi-lib.sh`, `scripts/on-discovery.d/`, `cli/`).

---

### User Story 2 — CI builds armv7h package alongside existing x86_64 builds (Priority: P2)

A maintainer running the project's CI pipeline wants the cross-compiled armv7h package to be produced as part of the same release workflow that already builds the native x86_64 arch and Debian packages. The armv7h build runs in a separate job but produces a release artifact in the same shape.

**Why this priority**: Automation is what makes the package actually ship. Without CI integration, the package only exists when a developer remembers to build it.

**Independent Test**: The GitHub Actions workflow includes a job named `package-arch-arm-rpi3` (or equivalent). On a tagged commit, that job produces and uploads a `.pkg.tar.zst` artifact. Triggering the workflow with a fake `TAG=v0.0.0-test` results in a working artifact.

**Acceptance Scenarios**:

1. **Given** a tagged commit on `main`, **When** the release workflow runs, **Then** a `.pkg.tar.zst` artifact appears in the workflow's upload step alongside the existing `.deb` and `.pkg.tar.zst` (archlinux amd64) artifacts.
2. **Given** the cross-compile job's container fails (e.g., network unavailable), **When** the workflow concludes, **Then** the existing native-package jobs still succeed and ship, and only the armv7h job is marked failed.

---

### User Story 3 — Build is reproducible across machines (Priority: P3)

Two different developers, both on x86_64 Linux with Docker, run the same build command and produce packages with identical content (ignoring `BUILD_DATE` and `PACKAGER` metadata fields). The build does not require outside state; it is hermetic within its container.

**Why this priority**: Reproducibility is what allows safe upgrades and security audits. A non-reproducible build cannot be trusted to be byte-equivalent between installs.

**Independent Test**: Build the same source SHA twice in fresh containers. `sha256sum` on the resulting `.pkg.tar.zst` files matches except for `BUILD_DATE`/`PACKAGER` fields.

**Acceptance Scenarios**:

1. **Given** the same source tree (specific git SHA), **When** two clean Docker builds are run, **Then** the produced packages' filenames match, the embedded binaries are byte-identical, and only timestamps differ.
2. **Given** the build script's input is identical, **When** the same build runs on a different host (or in CI), **Then** `pacman -Qlp` lists the same files.

---

### Edge Cases

- **Toolchain unavailable in container**: If the cross-compilation toolchain (`arm-linux-gnueabihf-gcc`, `arm-linux-gnueabihf-ld`, LDC-with-arm-target) cannot be installed via `pacman` in the container, the build must FAIL EARLY with a clear error message — not silently fall back to a wrong-arch binary.
- **LDC armv7h backend correctness**: Some code patterns (e.g., SIMD intrinsics, inline asm) may not work cleanly on armv7h. If `ldc2 --target=arm-unknown-linux-gnueabihf` fails or produces a binary that doesn't run on the target, the build must fail clearly rather than ship a broken binary.
- **NNCP cross-compile**: NNCP is a Go binary built from source by `scripts/build-nncp.sh`. Cross-compiling Go to armv7h requires `GOARCH=arm GOARM=7` environment variables set during the Go build step. If unset, `nncp-toss` ends up wrong-arch and breaks the `/nncp/receive` handler at runtime.
- **Source mount is read-only**: Container mounts the source read-only at `/src`. The build needs to generate `source/version_.d` (writable file) during build. The build must copy source to a writable location before writing.
- **Container-in-container**: CI may run without nested Docker. The flow should document that the cross-build **must** run inside a container (for hermeticity), and document any rootless/--privileged requirements upfront.
- **Wrong hardware detection**: If the operator mistakenly targets RPi 4 (64-bit) or RPi Zero W (single-core ARMv6), the package should still install but be flagged. Out of scope to auto-detect; document the prerequisite in the package's PKGINFO description.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: A single justfile recipe (e.g., `just package-arch-arm-rpi3`) MUST drive the entire build — entering the container, configuring the cross-compiler, building all artifacts, and producing the `.pkg.tar.zst`.
- **FR-002**: The build MUST produce a valid Arch Linux package (`.pkg.tar.zst` compressed with zstd) that `pacman` can parse and install.
- **FR-003**: The package's PKGINFO MUST declare `arch=armv7h`.
- **FR-004**: The package MUST contain `/usr/bin/mtls-hello` — an executable binary compiled to run on ARMv7-A with hard-float.
- **FR-005**: The package MUST contain all architecture-independent components: `handlers/`, `cli/`, and `scripts/` (including `cgi-lib.sh`, `sync-lib.sh`, `on-discovery.d/`, `gen-certs.sh`, `build-nncp.sh`, `install.sh`, `apache-config.sh`, package helpers, `log-capture.sh`, etc.).
- **FR-006**: The PKGINFO MUST declare **both** dependency classes using canonical Arch package names. Runtime (`depends =`) entries include `apache`, `bash`, `openssl`, `git`, `coreutils`, `grep`, `findutils`, `sed`, `awk`, `glibc`, `zstd`, etc. Build (`makedepends =`) entries include `arm-linux-gnueabihf-gcc`, `arm-linux-gnueabihf-glibc`, `binutils`, `pacman`, `ldc`, `dub`, `pkgconf`, `git`, `openssl`, `make`, `zstd`. Runtime dependencies MUST NOT be bundled inside the package when they can be installed from official Arch Linux ARM repos — pacman resolves them at install time on the target.
- **FR-013**: The container entrypoint MUST use `makepkg -s` (or equivalent shell pattern) so that all `makedepends` are auto-installed via pacman inside the cross-build environment before compile/link steps run. Builds MUST NOT rely on the user pre-installing toolchain packages outside the container.
- **FR-007**: NNCP and the LDC-compiled binary MUST both be cross-compiled for armv7h — no `x86_64` artifacts may end up inside the `.pkg.tar.zst` (verifiable via `file /usr/bin/mtls-hello` and `file ${pkg_prefix}/bin/nncp-*` reporting ARMv7+Linux).
- **FR-008**: The build MUST run inside a Docker/OCI container so the host system is not polluted. The container may be rootful (Docker-in-Docker for CI) or rootless (Podman).
- **FR-009**: The build MUST be idempotent: re-running the same `just` recipe twice with the same source produces a package whose payload is byte-identical (modulo `BUILD_DATE`/`PACKAGER`).
- **FR-010**: The build MUST fail FAST and LOUDLY (non-zero exit, clear log line) if the cross-compilation toolchain is unavailable — not silently produce a wrong-arch artifact.
- **FR-011**: On the target system, after `pacman -U mtls-hello-<v>-armv7h.pkg.tar.zst`, the mtls-hello binary MUST run successfully (verified by `mtls-hello --version` returning 0) on a true Arch Linux ARM RPi 3 Model B v1.2 installation OR via qemu-arm-static emulation of the same.
- **FR-012**: The build MUST emit its output `.pkg.tar.zst` to a known directory (e.g., `dist/` or a configurable output path) so downstream CI/release steps can pick it up.

### Key Entities

- **Build container**: a Docker image with armv7h cross-compilation toolchain installed via pacman. Ephemeral — started per build, never retained.
- **Output package**: a `.pkg.tar.zst` archive with `.PKGINFO`, `.MTREE`, `.INSTALL`, and the payload (`/usr/bin/mtls-hello`, `/usr/share/mtls-hello/...`).
- **PKGINFO metadata**: declares `pkgname`, `pkgver`, `pkgrel`, `arch=armv7h`, `depends`, `optdepends`, `provides`, `url`, `description`, `packager`, `builddate`.
- **Cross-compiled artifacts**: the D daemon binary (`mtls-hello`) for armv7h; NNCP Go programs (`nncp`, `nncp-toss`, `nncp-call`, etc.) for armv7h; bash scripts are architecture-independent.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: The produced `.pkg.tar.zst`'s `.PKGINFO` declares `arch=armv7h`. Verifiable by running `tar -xOf mtls-hello-*.pkg.tar.zst .PKGINFO | grep ^arch=`.
- **SC-002**: The package installs cleanly in an Arch Linux ARM RPi 3 chroot (verified via `qemu-arm-static` emulation OR actual hardware on a developer's bench). After install, `pacman -Qi mtls-hello` lists the package details.
- **SC-003**: After install, `/usr/bin/mtls-hello --version` exits with status 0 within 10 seconds, producing a non-empty version string.
- **SC-004**: `file /usr/bin/mtls-hello` reports `ELF 32-bit LSB executable, ARM, ...` and `file ${prefix}/bin/nncp-toss` likewise — confirming cross-compilation correctness.
- **SC-005**: A single justfile recipe (`just package-arch-arm-rpi3`) drives the entire build from source to package, with no manual steps.
- **SC-006**: Building completes in under 30 minutes on a typical CI runner (2 vCPU, 8 GB RAM).
- **SC-007**: The CI workflow produces the armv7h package alongside existing `.deb` and native-arch `.pkg.tar.zst` artifacts in the same release run.
- **SC-008**: Build is reproducible: re-running `just package-arch-arm-rpi3` with the same git SHA produces a `.pkg.tar.zst` whose payload files (under `./usr/`) are byte-identical between runs — verifiable by `tar -tf ... > file.list; for f in $(file.list); do sha256sum $f; done` sorted + diffed across two builds (excluding `.PKGINFO` timestamps).

## Assumptions

- **Build host**: x86_64 Linux with a recent Docker (or Podman) installed. macOS or native Windows hosts are out of scope — Linux is required.
- **Build-time network**: Required (the container uses `pacman -Syu` to fetch the toolchain). Production CI likely has this; air-gapped builds are out of scope.
- **Target hardware**: Raspberry Pi 3 Model B v1.2 (BCM2837, ARMv7-A Cortex-A53, hard-float, single-precision VFPv4 + NEON half-precision). Operator's Pi must already be running a current Arch Linux ARM image. ARMv8 (aarch64) Raspberry Pi models (Pi 4, Pi 5, etc.) are out of scope — they'd need a different arch target.
- **Cross-compilation toolchain**: Arch Linux's `arm-linux-gnueabihf-gcc`, `arm-linux-gnueabihf-binutils`, `arm-linux-gnueabihf-glibc` packages provide everything needed; LDC has a built-in `--target=arm-unknown-linux-gnueabihf` mode; Go uses `GOARCH=arm GOARM=7` environment variables.
- **Runtime dependencies** (Apache, bash, openssl, git, etc.) are NOT bundled in the package. They are declared in the PKGINFO `depends =` field and resolved by pacman at install time on the target — the operator does NOT need to pre-install them; `pacman -U mtls-hello-*.pkg.tar.zst` will pull them in automatically.
- **Build dependencies** (arm-linux-gnueabihf-gcc/glibc/binutils, ldc, dub, make, zstd, etc.) are NOT required to be present in the build container image ahead of time. They are declared in the PKGINFO `makedepends =` field and resolved inside the container by the standard `makepkg -s` invocation pattern (which calls `pacman -S --asdeps` on every listed `makedepends` to fulfil them). The cross-Dockerfile is therefore minimal — just `pacman -Syu --noconfirm pacman` plus a single `bash scripts/package-arch-arm-rpi3.sh` (or direct `makepkg -s`) command that converges on the package.
- **`sh` naming convention**: Arch packages use `bash` (not POSIX `sh`). Our handler/script files source `#!/bin/bash` and use bash-only features; the package's runtime depends includes `bash` and the assumption is that the boot environment on the target RPi uses bash paths, not a stripped-down POSIX shell.
- **No `--no-Docker` mode**: This build flow requires Docker. A pure-host build (without container) is acceptable as a future simplification but not required here.
- **`scripts/package-arch.sh` (existing)**: Will be the entry point inside the container. The dockerfile runs `bash scripts/package-arch.sh` after cross-compiling the binary to armv7h. This is the only existing script that will see a new cross-compile flavor; no other script needs ARM-specific changes.
