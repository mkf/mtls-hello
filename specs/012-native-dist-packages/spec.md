# Feature Specification: Native Distribution Packages

**Feature Branch**: `012-native-dist-packages`

**Created**: 2026-08-05

**Status**: Draft

**Input**: "Automated preparation of a Debian package on Debian, and an Arch Linux package on Arch Linux. No Guix."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Build a Debian Package on Debian (Priority: P1)

A developer or operator, on a Debian (or Ubuntu) machine with a D compiler available, runs a single command. The command builds the server binary from source using the system's native toolchain, stages the install tree, and produces a `.deb` package that can be installed with `dpkg -i` or `apt install ./file.deb`. The package installs the binary, handlers, hook templates, and a generated self-signed certificate, and registers a systemd user service.

**Why this priority**: Debian/Ubuntu is the most common deployment target. A native `.deb` integrates with the package manager, supports upgrades and clean removal, and is the natural distribution format on these systems.

**Independent Test**: On a Debian machine, run the package build command, then `dpkg -i` the resulting `.deb`, and verify the binary, handlers, cert, and systemd user unit are all in place and the service starts.

**Acceptance Scenarios**:

1. **Given** a Debian 12 machine with the build dependencies installed, **When** the operator runs the Debian packaging command, **Then** a `.deb` file is produced whose name includes the project name, version, and architecture.
2. **Given** the produced `.deb`, **When** the operator installs it with `dpkg -i`, **Then** the binary, handlers, hook templates, vendored or system libraries (as needed), a self-signed server certificate, and a systemd user unit are installed.
3. **Given** the package is installed, **When** the operator runs `systemctl --user start mtls-hello`, **Then** the service starts and listens for HTTPS connections.
4. **Given** the package is installed, **When** the operator runs `dpkg -r mtls-hello`, **Then** all package-owned files are removed (user data like certificates and repos are preserved).

---

### User Story 2 - Build an Arch Linux Package on Arch (Priority: P1)

A developer or operator, on an Arch Linux machine with a D compiler available, runs a single command. The command builds the server binary from source using the system's native toolchain, stages the install tree, and produces a `.pkg.tar.zst` package that can be installed with `pacman -U`. The package installs the same set of files as the Debian package.

**Why this priority**: Arch is the second named target. Native `pacman` packages integrate with the rolling-release workflow and `pacman`'s dependency tracking.

**Independent Test**: On an Arch machine, run the package build command, then `pacman -U` the resulting package, and verify the same installation outcomes as the Debian story.

**Acceptance Scenarios**:

1. **Given** an Arch Linux machine with the build dependencies installed, **When** the operator runs the Arch packaging command, **Then** a `.pkg.tar.zst` file is produced whose name includes the project name, version, and architecture.
2. **Given** the produced package, **When** the operator installs it with `pacman -U`, **Then** the binary, handlers, hook templates, a self-signed server certificate, and a systemd user unit are installed.
3. **Given** the package is installed, **When** the operator runs `systemctl --user start mtls-hello`, **Then** the service starts and listens for HTTPS connections.
4. **Given** the package is installed, **When** the operator runs `pacman -R mtls-hello`, **Then** all package-owned files are removed (user data is preserved).

---

### User Story 3 - Detect the Distro and Run the Right Build (Priority: P2)

The operator runs a single entry-point command that detects whether it is on Debian or Arch and dispatches to the appropriate packaging routine. If the distro is neither, the command prints a clear error listing the supported distros.

**Why this priority**: Convenience. The operator does not need to remember two separate commands. A single command works on both supported distros.

**Independent Test**: Run the entry-point command on Debian and verify it produces a `.deb`; run it on Arch and verify it produces a `.pkg.tar.zst`; run it on an unsupported distro and verify it exits with an error.

**Acceptance Scenarios**:

1. **Given** a Debian machine, **When** the operator runs the unified entry-point command, **Then** the Debian packaging routine runs and a `.deb` is produced.
2. **Given** an Arch machine, **When** the operator runs the unified entry-point command, **Then** the Arch packaging routine runs and a `.pkg.tar.zst` is produced.
3. **Given** an unsupported distro (e.g., Fedora), **When** the operator runs the entry-point command, **Then** the command exits non-zero with a message naming the supported distros.

---

### User Story 4 - Build Both Packages via Docker on Any Host (Priority: P1)

A developer on any Linux host with Docker installed — including an outdated or rolling-release distro like openSUSE Slowroll that cannot natively build for Debian or Arch — runs a single command. The command launches a Debian container and an Arch container, builds the respective native package inside each, and copies the finished `.deb` and `.pkg.tar.zst` out to the host's working directory. The Docker flow is perfectly portable: it works identically on any host with Docker, regardless of the host's own distribution, age, or installed compilers.

**Why this priority**: The developer's workstation is often not the deployment target. A portable Docker-based build lets one machine produce packages for both target distros without installing their toolchains natively, without Guix, and without cross-compilation complexity.

**Independent Test**: On a host with Docker but no D compiler (e.g., the openSUSE Slowroll dev machine), run the Docker build command, and verify both a `.deb` and a `.pkg.tar.zst` appear in the output directory, each installable on its respective target.

**Acceptance Scenarios**:

1. **Given** a host with Docker installed and the project source checked out, **When** the operator runs the Docker build command, **Then** both a Debian `.deb` and an Arch `.pkg.tar.zst` are produced in the output directory.
2. **Given** a host whose own distro is neither Debian nor Arch (e.g., openSUSE Slowroll), **When** the operator runs the Docker build command, **Then** both packages are still produced, because the build happens inside distro-matched containers, not on the host.
3. **Given** the host has no D compiler and no Guix installed, **When** the operator runs the Docker build command, **Then** the command still succeeds, because each container installs its own build toolchain from scratch.
4. **Given** the produced packages, **When** they are copied to their respective target machines and installed, **Then** they behave identically to packages produced by the native from-scratch scripts (US1/US2).

---

### Edge Cases

- The machine does not have a D compiler (LDC or DMD) installed — the build command detects this and prints a clear error listing the required package to install (`ldc` on Debian, `ldc` on Arch).
- The machine does not have `openssl` available — certificate generation is skipped with a warning; the package is still produced but the operator must provide certificates manually.
- The build dependencies are missing (e.g., OpenSSL development headers) — the build command detects the failure and prints the missing dependency.
- The package is installed a second time (upgrade) — existing user certificates are preserved; the binary and handlers are updated.
- A previous self-signed cert exists from a prior install — it is not overwritten.
- The host running the Docker build has no Docker daemon running — the command detects this and prints a clear error directing the operator to start Docker.
- The host is offline — the Docker build cannot pull base images or install build dependencies; the command fails with a clear network error.
- The Docker build is run a second time — containers are rebuilt or cached as appropriate; the output packages are overwritten with fresh builds.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: A single entry-point command MUST detect the host distribution (Debian/Ubuntu vs Arch) and dispatch to the matching packaging routine.
- **FR-002**: On Debian, the packaging routine MUST produce a `.deb` package installable via `dpkg -i`.
- **FR-003**: On Arch, the packaging routine MUST produce a `.pkg.tar.zst` package installable via `pacman -U`.
- **FR-004**: On an unsupported distro, the entry-point command MUST exit non-zero and print the names of the supported distros.
- **FR-005**: Both packaging routines MUST build the server binary from source using the host's native D compiler (no Guix, no vendored Guix libraries).
- **FR-006**: Both packages MUST install the binary, handlers, hook templates, and a systemd user unit under the appropriate system paths for each distro.
- **FR-007**: The systemd user unit MUST reference absolute paths to the installed binary and certificate locations and set the library path appropriately for the host's libraries.
- **FR-008**: Both packages MUST generate a self-signed server certificate (CN=hostname, 10-year validity, key mode 0600) on first install if none exists, and MUST NOT overwrite an existing certificate on upgrade.
- **FR-009**: Both packages MUST declare their runtime dependencies (openssl, the D runtime libraries if not statically linked) so the package manager installs them automatically.
- **FR-010**: Both packages MUST support clean removal via the package manager, removing all package-owned files while preserving user data (certificates, repositories, trust store).
- **FR-011**: The packaging routines MUST run entirely on the target distro — no Guix, no cross-compilation from the dev machine.
- **FR-012**: If the D compiler is not found, the build command MUST exit non-zero with a message naming the package to install (`ldc`).
- **FR-013**: A Docker-based build command MUST be available that, on any host with Docker, produces both a Debian package and an Arch package without requiring the host to have a D compiler, Guix, or the target distros installed.
- **FR-014**: The Docker build command MUST use distro-matched base containers (a Debian base image for the `.deb`, an Arch base image for the `.pkg.tar.zst`) so that the resulting packages are built against the correct target libraries.
- **FR-015**: Each Docker build container MUST install its own build toolchain (D compiler, OpenSSL development headers, packaging tools) from scratch from the container's native package manager — no Guix, no host-mounted toolchains.
- **FR-016**: The Docker build command MUST copy the finished packages out of the containers into a designated output directory on the host.
- **FR-017**: The Docker build flow MUST be portable: it MUST produce identical packages regardless of the host's own distribution, age, or installed compilers, depending only on Docker being available.
- **FR-018**: Packages produced by the Docker build MUST be byte-for-byte equivalent in behavior to packages produced by the native from-scratch scripts (US1/US2) — same files, same paths, same post-install behavior.
- **FR-019**: If Docker is not available or the daemon is not running, the Docker build command MUST exit non-zero with a clear error message.

### Key Entities

- **Debian package (.deb)**: A standard Debian binary package containing the install tree, control metadata (dependencies, description), and postinst/prerm scripts for cert generation and service management.
- **Arch package (.pkg.tar.zst)**: A standard Arch binary package containing the install tree, `.PKGINFO`, `.INSTALL` script, and the install tree under the package root.
- **Install tree**: The set of files both packages deliver — the server binary, handler scripts, hook templates, and a systemd user unit template.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: On a Debian 12 machine, the build command produces exactly one `.deb` file; installing it results in a running `mtls-hello` systemd user service within 2 minutes of package installation.
- **SC-002**: On an Arch Linux machine, the build command produces exactly one `.pkg.tar.zst` file; installing it results in a running `mtls-hello` systemd user service within 2 minutes of package installation.
- **SC-003**: Uninstalling either package removes all package-owned files; user certificates and repositories remain.
- **SC-004**: Upgrading (reinstalling) either package preserves an existing server certificate (fingerprint unchanged).
- **SC-005**: On a host that is neither Debian nor Arch but has Docker (e.g., openSUSE Slowroll), the Docker build command produces both a `.deb` and a `.pkg.tar.zst` within 15 minutes; neither package requires the host to have a D compiler or Guix installed.
- **SC-006**: Packages produced via Docker install and run identically to packages produced via the native from-scratch scripts — the same files exist at the same paths after installation.

## Assumptions

- The target machine is 64-bit x86 Linux running Debian 12+, Ubuntu 22.04+, or Arch Linux.
- The target machine has, or can install, a D compiler (`ldc`) and the OpenSSL development libraries via its native package manager.
- The target machine has the distro's native packaging tools installed (`dpkg-deb` on Debian, `makepkg`/`pacman` on Arch).
- The binary is built natively on the target; no Guix is used at any point in the package build.
- The D runtime and vibe.d dependencies are available on the target through the D package manager (`dub`) or are statically linked where practical.
- User data (certificates, bare repos, trust store) lives under the user's home directory and is not touched by the package manager on removal.
- For the Docker build path, the host has Docker (or a compatible container engine) installed and the daemon running. The host's own distribution, compilers, and libraries are irrelevant — all building happens inside containers.
- The Docker base images used are standard, publicly available official images for each target distro (e.g., `debian:bookworm`, `archlinux:latest`).
- The Docker build mounts the project source directory read-only into each container so the containers build from the same source tree without copying it into the image.
