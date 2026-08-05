# Feature Specification: Self-Extracting Portable Installer

**Feature Branch**: `011-self-extracting-installer`

**Created**: 2026-08-05

**Status**: Draft

**Input**: A `just` target that produces a self-extracting shell script. The script bundles the compiled binary, vendored runtime libraries, handlers, hook templates, and an embedded install-service unit. It provides `install` and `install-service` subcommands. The filename includes the git commit hash, date, and a `-dirty` suffix when the working tree is unclean.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Build the Self-Extracting Installer (Priority: P1)

An operator runs `just self-extract` (or equivalent just target) on their development machine (with Guix). The recipe produces a single self-extracting shell script named `mtls-hello-installer-<commithash>-<YYYYMMDD>[-dirty].sh`. The script is self-contained — it carries everything needed to install and configure the server on a bare Debian/Ubuntu 64-bit x86 system.

**Why this priority**: Without this, deployment requires Guix on every target machine. The self-extracting installer is the only distribution mechanism for production use outside the developer's workstation.

**Independent Test**: Run `just self-extract`, verify the output file exists at the expected name pattern, and running `bash <file> --help` prints usage information without performing any installation.

**Acceptance Scenarios**:

1. **Given** a clean working tree at a known commit, **When** `just self-extract` runs, **Then** a file `mtls-hello-installer-<short-hash>-<date>.sh` is produced.
2. **Given** a dirty working tree (uncommitted changes), **When** `just self-extract` runs, **Then** the filename includes `-dirty` (e.g., `mtls-hello-installer-abc1234-20260805-dirty.sh`).
3. **Given** the produced script, **When** `bash <script> --help` is invoked, **Then** usage text describing `install` and `install-service` subcommands is printed, with exit code 0.

---

### User Story 2 - Install on a Bare Target System (Priority: P1)

An operator copies the self-extracting script to a Debian 12 x86_64 machine that has `openssl` installed (but no Guix, no D compiler, no vibe.d libraries). They run `bash mtls-hello-installer-... install`. The script creates the same `~/.local` directory layout as `just install` on the dev machine — binary, vendored libraries, handlers, hook templates, and a self-signed server certificate.

**Why this priority**: This is the core deployment action. Everything else depends on the ability to install on a target machine.

**Independent Test**: On a Debian x86_64 system (or in a Docker container / VM simulating one), run `bash <installer> install`, then verify the binary (`~/.local/bin/mtls-hello --version`) works, the vendored `~/.local/lib/mtls-hello/` directory is populated, handlers exist at `~/.local/share/mtls-hello/handlers/`, and a self-signed certificate exists at `~/.local/share/mtls-hello/certs/certs/server.crt`.

**Acceptance Scenarios**:

1. **Given** the self-extracting script and a target system with openssl available, **When** `bash <script> install` runs, **Then** the binary, handlers, hook templates, vendored libraries, and a self-signed server certificate are placed under `~/.local` exactly mirroring the dev-machine `just install` output.
2. **Given** that `just install` on the target was already run, **When** `bash <script> install` runs again, **Then** existing certificates are NOT overwritten (fingerprint preserved).
3. **Given** openssl is not available on the target, **When** `bash <script> install` runs, **Then** a warning is printed but the script still succeeds (certificates are skipped, binary and handlers are still installed).

---

### User Story 3 - Install the Systemd Service on Target (Priority: P2)

After installing the binary, the operator runs `bash mtls-hello-installer-... install-service`. This creates the systemd user unit at `~/.config/systemd/user/mtls-hello.service`, identical to what `just install-service` produces on the dev machine (absolute paths, LD_LIBRARY_PATH, --port=0, --data-dir).

**Why this priority**: The service needs to be managed by systemd for auto-start and restart on failure. This is required for production but can be done manually via the systemd unit template if needed.

**Independent Test**: After running `bash <installer> install-service`, verify the unit file exists, passes `systemd-analyze --user verify`, and the service starts and responds to HTTPS requests.

**Acceptance Scenarios**:

1. **Given** the script and a prior `install`, **When** `bash <script> install-service` runs, **Then** a systemd user unit is created at `~/.config/systemd/user/mtls-hello.service` with absolute cert paths, LD_LIBRARY_PATH pointing to vendored libs, and `--port=0`.
2. **Given** no prior `install`, **When** `bash <script> install-service` runs, **Then** the script exits with a non-zero status and an error message explaining that `install` must be run first.

---

### Edge Cases

- Target system has an older libc (e.g., glibc 2.31 on Debian 11) — the vendored LDC runtime libraries may be incompatible. The script should detect the glibc version and warn if it's below the minimum required.
- Target disk is full — the extraction step fails with a clear error before leaving partial files.
- Script is run as root — `~` expands to `/root`, which is probably unintended. Print a warning but proceed.
- Script is piped directly to `bash` (`curl ... | bash`) — this is not supported. The script must be saved to a file first (`curl -o installer.sh && bash installer.sh install`).
- The self-extracting script itself is very large (tens of MB) due to embedded binary and libraries. This is expected and acceptable.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: `just self-extract` MUST produce a single executable (via `bash`) shell script.
- **FR-002**: The output filename MUST follow the pattern `mtls-hello-installer-<short-commit-hash>-<YYYYMMDD>[-dirty].sh` where `-dirty` is appended only when `git status --porcelain` is non-empty.
- **FR-003**: The script MUST support subcommands: `install` and `install-service`.
- **FR-004**: Running `bash <script> --help` or `bash <script>` (no subcommand) MUST print usage and exit 0.
- **FR-005**: The `install` subcommand MUST extract the binary to `~/.local/bin/mtls-hello`, vendored libraries to `~/.local/lib/mtls-hello/`, handlers to `~/.local/share/mtls-hello/handlers/`, and hook templates (`*.new`) to `~/.local/share/mtls-hello/scripts/`.
- **FR-006**: The `install` subcommand MUST generate a self-signed server certificate at `~/.local/share/mtls-hello/certs/certs/server.crt` (CN=hostname, 10yr validity, key mode 0600) if none exists — never overwriting an existing certificate.
- **FR-007**: The `install` subcommand MUST warn but succeed if `openssl` is not available on the target system.
- **FR-008**: The `install-service` subcommand MUST create a systemd user unit at `~/.config/systemd/user/mtls-hello.service` with absolute paths to the installed binary, cert, key, and vendored library directory.
- **FR-009**: The `install-service` subcommand MUST refuse to run if the installed binary (`~/.local/bin/mtls-hello`) is not found, exiting with a non-zero status and an error message.
- **FR-010**: The generated script MUST work on a target system that has `bash`, `openssl` (CLI only), `systemd` (user instance), and standard POSIX utilities (`mkdir`, `cp`, `chmod`, `cat`, etc.) — but NO Guix, D compiler, or vibe.d libraries.
- **FR-011**: The `just self-extract` recipe MUST require the binary to be pre-built; if `./mtls-hello` does not exist, the recipe MUST fail with a clear error message.
- **FR-012**: The embedded binary and libraries MUST be included as base64-encoded payloads within the shell script, extracted at runtime by the subcommands.

### Key Entities

- **Self-extracting script**: A bash script with a header (subcommand dispatch + extraction logic) and a trailer (base64-encoded tarball of the install tree).
- **Install tree**: The contents that `install` places under `~/.local`: `bin/mtls-hello`, `lib/mtls-hello/*.so*`, `share/mtls-hello/{handlers/*, scripts/*.new}`.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Running `just self-extract` on the dev machine produces exactly one `.sh` file whose name matches the commit-hash-date-dirty pattern.
- **SC-002**: On a Debian 12 x86_64 system without Guix, running `bash <installer> install && bash <installer> install-service && systemctl --user daemon-reload && systemctl --user start mtls-hello` results in a running service that responds to `curl https://localhost:<port>/hello` with "hello" (after cert exchange).
- **SC-003**: Filename correctly reflects dirty state: a clean tree produces no `-dirty` suffix; touching a file produces `-dirty`.
- **SC-004**: `bash <installer> install-service` without prior `install` exits non-zero with an error message.

## Assumptions

- The development machine has Guix, the Guix shell, and `just` available. The build recipe runs inside the Guix shell.
- The target machine is 64-bit x86 Linux with glibc 2.31 or later (Debian 11+). Older glibc versions may fail due to the LDC runtime.
- The target machine has `openssl` available as a CLI tool (for certificate generation). If not, the operator provides certificates manually.
- The target machine has `systemd` with user instance support (`systemctl --user`).
- The script is executed as a file (`bash script.sh install`), not directly piped from `curl`. Direct-pipe support is not required.
- The self-extracting script is deployed via `scp`, USB stick, `curl -o installer.sh && bash installer.sh install`, or similar file transfer — not via a package manager and not via direct pipe-to-bash.
