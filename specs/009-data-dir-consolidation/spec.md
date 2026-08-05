# Feature Specification: Data Directory Consolidation

**Feature Branch**: `009-data-dir-consolidation`

**Created**: 2026-08-05

**Status**: Draft

**Input**: User description: "make everything .local/share, the on-discover, the handlers, the whatnot to come in the future, to require .local/share either through the install-systemd (and used in install.sh to put there nonexistent scripts (or give it .new files) or through providing it to command line"

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Single Data Directory for All Runtime Files (Priority: P1)

An operator installs mtls-hello and wants all runtime files (handler scripts, discovery callback, and any future scripts) to live under one configurable directory. Instead of setting `--handlers-dir`, `CALLBACK_SCRIPT`, and future flags individually, they set a single `--data-dir` flag and everything is derived from it.

**Why this priority**: Currently handlers, callback, trust, and purgatory paths are set independently through different mechanisms (CLI flags, env vars). As the application grows, each new script type would require its own flag, creating configuration sprawl. A single base directory eliminates this.

**Independent Test**: Start the server with `--data-dir=/tmp/test-data`, verify that handler scripts are loaded from `/tmp/test-data/handlers/` and the discovery callback uses `/tmp/test-data/scripts/on-discover.sh` without additional configuration.

**Acceptance Scenarios**:

1. **Given** a server started with `--data-dir=/srv/mtls-hello` and handlers at `/srv/mtls-hello/handlers/`, **When** an HTTP request matches a handler name, **Then** the handler executes from the derived path.
2. **Given** a server started with `--data-dir=/srv/mtls-hello`, **When** a peer is discovered via multicast, **Then** the callback script is spawned from `/srv/mtls-hello/scripts/on-discover.sh` (if CALLBACK_SCRIPT is not explicitly set).
3. **Given** a server started with `--data-dir=/srv/mtls-hello --handlers-dir=/custom`, **When** an HTTP request arrives, **Then** handlers are loaded from `/custom` (explicit override takes precedence over derived path).

---

### User Story 2 - Install Creates Complete Directory Tree (Priority: P2)

After running `just install`, the operator's `~/.local/share/mtls-hello/` directory contains all expected subdirectories and stub files, even for scripts that don't exist yet. This makes it clear where future customizations should be placed.

**Why this priority**: A self-documenting filesystem layout reduces onboarding friction. Placeholder `.new` files show operators what they can customize without reading docs.

**Independent Test**: Run `just install` with a temporary HOME, verify the directory tree contains `handlers/`, `scripts/on-discover.sh`, and any stub files with `.new` suffix.

**Acceptance Scenarios**:

1. **Given** a fresh install with `just install`, **When** the operator inspects `~/.local/share/mtls-hello/scripts/`, **Then** they see `on-discover.sh` (the real script) and placeholder files like `pre-push.sh.new` indicating optional future hooks.
2. **Given** an existing install, **When** `just install` is re-run, **Then** existing custom scripts are not overwritten, but stub `.new` files are updated.

---

### User Story 3 - Systemd Unit Uses Single Data Directory (Priority: P3)

The generated systemd user unit references the data directory once, and all runtime paths are derived from it. The operator only needs to set one path when customizing.

**Why this priority**: The systemd unit is the primary production deployment method (feature 007). Consistency between CLI and systemd configuration reduces errors.

**Independent Test**: Generate a systemd unit with `just install-service`, verify the `ExecStart` line contains a single `--data-dir` flag and no individual handler/callback path overrides.

**Acceptance Scenarios**:

1. **Given** a systemd unit generated after `just install && just install-service`, **When** the operator inspects the service file, **Then** `ExecStart` contains `--data-dir=%h/.local/share/mtls-hello` and no `--handlers-dir` or `CALLBACK_SCRIPT`.
2. **Given** a running service with `--data-dir=%h/.local/share/mtls-hello`, **When** the operator places a new handler in `~/.local/share/mtls-hello/handlers/`, **Then** the handler is available without restarting (or after a service reload).

---

### Edge Cases

- What happens if `--data-dir` points to a non-existent directory? The server should create it (like it does for trust/purgatory dirs today), or fail with a clear error if the parent directory is not writable.
- What happens if both `--data-dir` and `--handlers-dir` are set? The explicit `--handlers-dir` takes precedence; `--data-dir` only provides defaults for paths not explicitly configured.
- What happens if `--data-dir` is set but `CALLBACK_SCRIPT` is also set? The explicit `CALLBACK_SCRIPT` takes precedence.
- What if future features add new sub-paths (e.g., `hooks/`, `templates/`)? They are derived from `--data-dir` by convention, with individual overrides possible.
- What about `--trust-dir` and `--purgatory-dir`? These are security-sensitive paths (containing certificates) and should NOT be placed under the data directory. They remain independent CLI flags.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The server MUST accept a `--data-dir=PATH` CLI flag that specifies the base directory for all runtime data files (handlers, scripts, future extensions).
- **FR-002**: When `--data-dir` is set, `--handlers-dir` MUST default to `<data-dir>/handlers` (unless explicitly overridden).
- **FR-003**: When `--data-dir` is set and `CALLBACK_SCRIPT` is not explicitly set, the callback path MUST default to `<data-dir>/scripts/on-discover.sh`.
- **FR-004**: Individual path overrides (`--handlers-dir`, `CALLBACK_SCRIPT`) MUST take precedence over paths derived from `--data-dir`.
- **FR-005**: The `CALLBACK_SCRIPT` env var MUST be superseded by the `--data-dir` derivation: if `--data-dir` is set, the callback defaults to `<data-dir>/scripts/on-discover.sh`. If neither `--data-dir` nor `CALLBACK_SCRIPT` is set, the callback is disabled (no default).
- **FR-006**: `just install` MUST create the complete directory tree under `~/.local/share/mtls-hello/` including `handlers/` and `scripts/`.
- **FR-007**: `just install` MUST install the real `on-discover.sh` to `~/.local/share/mtls-hello/scripts/on-discover.sh`.
- **FR-008**: `just install` MAY place `.new` stub files for future optional scripts (e.g., `pre-push.sh.new`) to document the extension points without deploying active scripts.
- **FR-009**: `just install-service` MUST generate a systemd unit that uses `--data-dir=%h/.local/share/mtls-hello` instead of individual `--handlers-dir` and `CALLBACK_SCRIPT` entries.
- **FR-010**: `--trust-dir` and `--purgatory-dir` MUST NOT be affected by `--data-dir` — they remain independently configurable CLI flags with their existing defaults.

### Key Entities

- **Data directory**: A single base directory (`--data-dir`) from which all runtime sub-paths are derived: `handlers/`, `scripts/on-discover.sh`, and future `hooks/`, `templates/`, etc.
- **Path override**: An individual CLI flag (`--handlers-dir`) or env var (`CALLBACK_SCRIPT`) that takes precedence over the data-dir derivation when explicitly set.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: An operator can configure all runtime paths by setting a single `--data-dir` flag — no individual handler or callback paths are required.
- **SC-002**: Running `just install && just install-service` produces a systemd unit where all runtime paths are expressed as sub-paths of one directory.
- **SC-003**: Adding a new handler script to the data directory's `handlers/` subdirectory makes it available to the running server within the same time frame as the current `--handlers-dir` behavior (no additional latency).
- **SC-004**: The existing individual path overrides (`--handlers-dir`, `CALLBACK_SCRIPT`) continue to work when `--data-dir` is not set, preserving backward compatibility.

## Assumptions

- The operator is responsible for choosing an appropriate data directory path. `just install` suggests `~/.local/share/mtls-hello` as the conventional location.
- The `--data-dir` default is empty (no default) — the binary does not guess a path. The operator must provide it explicitly or rely on individual path flags.
- Certificate-related paths (`--trust-dir`, `--purgatory-dir`) are excluded from the data directory because they have different security and lifecycle requirements.
- Existing BATS tests that use `--handlers-dir` and `CALLBACK_SCRIPT` directly will continue to work without modification (backward compatibility).
- Future extensions (e.g., `hooks/`, `templates/`) will follow the same convention: `<data-dir>/<subdirectory>` by default, overridable via specific flags.
