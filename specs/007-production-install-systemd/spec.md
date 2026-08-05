# Feature Specification: Production-Ready Install & Systemd Service

**Feature Branch**: `007-production-install-systemd`

**Created**: 2026-08-05

**Status**: Implemented

**Input**: User description: "make it run on a random port in production, prepare a `just install` that will do me a ~/.local, and make it make me a systemd user service unit for my user"

## User Scenarios & Testing *(mandatory)*

### User Story 1 - `just install` to ~/.local (Priority: P1)

An operator wants to install the mtls-hello binary and its runtime dependencies (certificates, handler scripts) into their home directory under `~/.local` so that the server can run without depending on the source tree or a Guix shell.

**Why this priority**: Installation is the foundation — without it, the binary can only run via `dub run` inside a Guix shell. Everything else (random port, systemd) requires an installed binary.

**Independent Test**: Run `just install` in a clean checkout, verify the binary is placed at `~/.local/bin/mtls-hello`, the default handlers are at `~/.local/share/mtls-hello/handlers/`, and `~/.local/bin/mtls-hello --version` prints version info. No Guix shell needed to run the installed binary.

**Acceptance Scenarios**:

1. **Given** a built `mtls-hello` binary exists (from `just build`), **When** the operator runs `just install`, **Then** the binary is copied to `~/.local/bin/mtls-hello`, the default `handlers/` directory is copied to `~/.local/share/mtls-hello/handlers/`, and the script exits 0.
2. **Given** a previous installation already exists, **When** the operator runs `just install` again, **Then** existing files are overwritten cleanly (no errors, no stale files from old versions) and the script exits 0.
3. **Given** a fresh machine with no `~/.local/bin` directory, **When** the operator runs `just install`, **Then** the directory is created automatically (no manual `mkdir` needed).
4. **Given** the installed binary at `~/.local/bin/mtls-hello`, **When** the operator runs it without a Guix shell, **Then** it starts and listens on the specified or default port (assuming system OpenSSL 3.x libraries are available).
5. **Given** `~/.local/bin` is not on the operator's PATH, **When** the install completes, **Then** an informational message reminds the operator to add `~/.local/bin` to their PATH.

---

### User Story 2 - Random Port in Production (Priority: P2)

An operator deploying the server to production does not want to hard-code a listen port. When the port argument is omitted or set to `0`, the server picks a random available port from the ephemeral range, reports the chosen port on stderr, and prints the chosen port to a configurable port-file so the process manager (systemd) can read it.

**Why this priority**: Random-port is a production best practice for services that discover each other. It depends on US1 (the installed binary must be runnable), but the port behavior can be tested independently.

**Independent Test**: Start the server with `--port=0`, verify it binds to a non-zero port, stdout (or a port-file) contains the chosen port, and a simple curl to that port works.

**Acceptance Scenarios**:

1. **Given** the server is started with `--port=0`, **When** it binds, **Then** the chosen port is written to stdout in a machine-parseable format (e.g., `PORT=n` or just the number), and a log line on stderr indicates the port.
2. **Given** the server is started with `--port=0` and `--port-file=/run/user/1000/mtls-hello.port`, **When** it binds, **Then** the chosen port number is written to that file (just the number, no trailing newline required) so that systemd's `ExecStartPost` or monitoring can read it.
3. **Given** the server is started with `--port=8443`, **When** it binds, **Then** it listens on port 8443 (existing fixed-port behavior preserved).
4. **Given** the server is started with no port argument, **When** it binds, **Then** it listens on port 8443 (existing default preserved for backward compatibility).
5. **Given** the operating system has no free ephemeral ports, **When** the server tries to bind on port 0, **Then** it exits with a non-zero status and a clear error message on stderr.

---

### User Story 3 - Systemd User Service Unit (Priority: P3)

An operator wants to run mtls-hello as a user-level systemd service that starts automatically on login and restarts on failure.

**Why this priority**: systemd integration is the final polish — it provides automatic startup, restart, and log capture. It depends on US1 (install) and works best with US2 (random port), but neither is a hard blocker.

**Independent Test**: Run `just install-service`, verify a valid `.service` file is placed at `~/.config/systemd/user/mtls-hello.service`, `systemctl --user daemon-reload` succeeds, `systemctl --user start mtls-hello` starts the server, and port file contains a valid port.

**Acceptance Scenarios**:

1. **Given** the operator has run `just install` and `just install-service`, **When** they run `systemctl --user start mtls-hello`, **Then** the service starts and a port-file at `%t/mtls-hello.port` contains the chosen port.
2. **Given** the service is running, **When** the operator runs `systemctl --user status mtls-hello`, **Then** the output shows `active (running)` and recent log lines from the server.
3. **Given** the server process exits with a non-zero code, **When** systemd observes the failure, **Then** the service is automatically restarted after a short delay (Restart=on-failure).
4. **Given** the operator wants to stop the service, **When** they run `systemctl --user stop mtls-hello`, **Then** the server shuts down cleanly within 5 seconds.
5. **Given** the service unit file does not yet exist, **When** the operator runs `just install-service`, **Then** the unit file is created at `~/.config/systemd/user/mtls-hello.service` with correct `ExecStart` pointing to `~/.local/bin/mtls-hello`, and an informational message tells the operator the next steps (`systemctl --user daemon-reload; systemctl --user enable --now mtls-hello`).

---

### Edge Cases

- What happens when `~/.local` or `~/.config/systemd/user` does not exist? The install commands must create them automatically.
- What happens if the installed binary's runtime dependencies (e.g., OpenSSL 3.x) are not available on the host? The binary fails at startup with a clear error message from the dynamic linker. The install and service scripts do not need to detect this.
- What happens if `%t` (XDG_RUNTIME_DIR) is not set when the service starts? systemd sets it automatically for user services; the service unit uses the `%t` specifier which systemd resolves at runtime.
- What happens if the port-file location is not writable? The server logs an error and continues running (the port is still available on stderr).
- What happens if `just install-service` is run before `just install`? The script warns that `~/.local/bin/mtls-hello` doesn't exist yet and exits non-zero.
- What happens if the operator moves `~/.local/bin/mtls-hello` after installing the service? The service fails to start; `systemctl --user status` shows the exit code and the reason.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: `just install` MUST copy the compiled `mtls-hello` binary to `~/.local/bin/mtls-hello`, creating the directory if it doesn't exist.
- **FR-002**: `just install` MUST copy the `handlers/` directory to `~/.local/share/mtls-hello/handlers/`, creating the directory tree if it doesn't exist.
- **FR-003**: `just install` MUST preserve file permissions (the binary remains executable, scripts remain executable).
- **FR-004**: The server MUST support a `--version` flag that prints the version string and exits 0.
- **FR-005**: When started with `--port=0`, the server MUST bind to a random available ephemeral port and print the chosen port number to stdout (machine-parseable: just the number).
- **FR-006**: The server MUST support a `--port-file=PATH` option. When given, the chosen port number is written to that file (just the number, no trailing newline).
- **FR-007**: When started without `--port` or with an explicit non-zero port, the server MUST preserve its existing behavior (default port 8443, explicit port binds as specified).
- **FR-008**: The port-file MUST be written atomically (write to temp file, then rename) so that watchers see only complete content.
- **FR-009**: `just install-service` MUST generate a systemd user service unit file at `~/.config/systemd/user/mtls-hello.service`.
- **FR-010**: The generated service unit MUST use `ExecStart` pointing to the installed binary at `%h/.local/bin/mtls-hello` with appropriate flags including `--port=0 --port-file=%t/mtls-hello.port`.
- **FR-011**: The generated service unit MUST configure `Restart=on-failure` and `RestartSec=5s`.
- **FR-012**: The generated service unit MUST log to the journal (standard systemd behavior — no special config needed).
- **FR-013**: `just install-service` MUST refuse to run (exit non-zero with a warning) if `~/.local/bin/mtls-hello` does not exist.
- **FR-014**: After `just install-service`, the script MUST print the commands the operator needs to run: `systemctl --user daemon-reload` and `systemctl --user enable --now mtls-hello`.

### Key Entities

- **Installed binary**: The compiled `mtls-hello` executable placed at `~/.local/bin/mtls-hello`. Key attributes: path, version, file permissions.
- **Shared data**: Handler scripts and associated files placed under `~/.local/share/mtls-hello/`. Key attributes: base path, subdirectories (handlers/).
- **Service unit file**: A systemd `.service` descriptor at `~/.config/systemd/user/mtls-hello.service`. Key attributes: ExecStart command, restart policy, port-file path.
- **Port file**: A small file at a configurable path containing just the listen port number. Written by the server process, read by systemd's `ExecStartPost` or monitoring scripts.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: An operator can go from a clean checkout to a running systemd-managed service in under 60 seconds (build → install → install-service → systemctl start).
- **SC-002**: The installed binary starts and serves requests without the source tree or Guix shell present (assuming host OpenSSL 3.x is available).
- **SC-003**: When `--port=0` is used, the server never fails due to port conflicts (the OS guarantees a free port).
- **SC-004**: The generated service unit passes `systemd-analyze verify` with no errors or warnings.
- **SC-005**: After `systemctl --user start mtls-hello`, the server is serving requests within 3 seconds. *(Verified manually; server starts quickly; not tested in CI because it requires a systemd user instance.)*
- **SC-006**: The service automatically restarts within 10 seconds of a crash (RestartSec=5s + startup time). *(Config is tested via unit file generation; actual restart timing relies on systemd's built-in behavior.)*

## Assumptions

- The operator's system has OpenSSL 3.x libraries available at runtime (the binary is linked dynamically against them). If the host only has LibreSSL, the operator must provide a compatible OpenSSL via `LD_LIBRARY_PATH`.
- `~/.local/bin` follows the XDG Base Directory specification and the operator will add it to PATH themselves if not already present (the install script reminds them).
- The operator uses a Linux distribution with systemd (the service unit uses systemd user-instance features).
- The `%t` systemd specifier (XDG_RUNTIME_DIR, typically `/run/user/<UID>`) is writable and available on the target system.
- The default handler scripts shipped with the source tree (`handlers/bundle.post.sh`) are the ones to install. Custom operator scripts are managed separately and out of scope.
- Certificates (server cert, key, trust store, purgatory) are operator-managed — the install and service scripts use sensible defaults but expect the operator to configure paths via CLI flags in the service unit override or environment.
