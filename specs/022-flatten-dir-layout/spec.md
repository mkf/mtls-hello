# Feature Specification: Flatten Directory Layout

**Feature Branch**: `022-flatten-dir-layout`

**Created**: 2026-08-06

**Status**: Draft

**Input**: User description: "eliminate default-paths nesting of trust as certs/hosts and of purgatory within certs; make certs/certs not nested and rename it to identity; our cert should be named per our host name; add an automatic non-interactive migration that moves files and removes the empty directories behind"

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Trust and purgatory live at the top level (Priority: P1)

As an operator, I want the trust store and the purgatory quarantine to live directly under the data directory (and under simple relative defaults), not nested inside a `certs/` directory, so the layout is flat and predictable.

**Why this priority**: This is the primary structural change requested; everything else builds on it.

**Independent Test**: On a fresh setup, the trust directory resolves to `<data-dir>/hosts` (fallback `hosts`) and the purgatory directory to `<data-dir>/purgatory` (fallback `purgatory`); no `certs/hosts` or `certs/purgatory` path is used by default.

**Acceptance Scenarios**:

1. **Given** a host started with `--data-dir=DIR`, **When** the daemon resolves directories, **Then** trust = `DIR/hosts` and purgatory = `DIR/purgatory`.
2. **Given** a host started without `--data-dir`, **When** defaults are used, **Then** trust = `hosts` and purgatory = `purgatory` (relative), never `certs/hosts`/`certs/purgatory`.
3. **Given** an explicit `--trust-dir` or `--purgatory-dir`, **When** the daemon runs, **Then** the explicit path wins over the new defaults.

---

### User Story 2 - Identity directory replaces the nested certs/certs (Priority: P2)

As an operator, I want my machine's own certificate and key to live in a single flat `identity/` directory, named after my hostname, so I can see at a glance which file is "my identity" and share it with peers.

**Why this priority**: Renaming and de-nesting our own key material is the second structural change; it also makes the trust-exchange story cleaner (the file to share is `identity/<my-hostname>.crt`).

**Independent Test**: A fresh install produces `identity/<hostname>.crt` and `identity/<hostname>.key`; no `certs/certs/` or `certs/private/` directories exist.

**Acceptance Scenarios**:

1. **Given** a fresh install, **When** certificates are generated, **Then** they are written to `identity/<hostname>.crt` and `identity/<hostname>.key`.
2. **Given** the hostname is X, **When** a peer trusts us, **Then** the file a peer would place in its trust directory is naturally named `X.crt` (matching the existing `<trust-dir>/<hostname>.crt` convention).

---

### User Story 3 - Automatic, non-interactive migration (Priority: P2)

As an existing user, I want my old nested layout moved to the new flat layout automatically, without any prompts or manual steps, and with the empty old directories cleaned up.

**Why this priority**: Existing installs (dev/test setups) must not break or require manual fixing; the migration is the safety net that makes the rename safe to ship.

**Independent Test**: Given a legacy layout (`certs/hosts`, `certs/purgatory`, `certs/certs/server.crt`, `certs/private/server.key`), running the program or installer produces the new layout and removes the empty legacy directories, with no interaction.

**Acceptance Scenarios**:

1. **Given** a legacy install with old paths populated, **When** the program starts (or install runs), **Then** files are moved to the new locations and the old empty directories are removed.
2. **Given** the migration already ran once, **When** it runs again, **Then** it is a harmless no-op (idempotent).
3. **Given** only some legacy pieces exist (e.g., a cert but no key), **When** migration runs, **Then** the existing pieces are moved, missing pieces are ignored, and the run does not fail.
4. **Given** a legacy directory is not empty after the move (e.g., unrelated files), **When** migration runs, **Then** the directory is left in place with a warning, and the program continues.

---

### Edge Cases

- What happens when the old directories do not exist at all? (Migration is skipped; fresh layout is used.)
- What happens when an explicit `--trust-dir`/`--purgatory-dir` is given that equals a legacy path? (Migration must not move a path the user explicitly chose.)
- What happens when the hostname contains characters unsafe for filenames? (The identity filename is sanitized to a safe form.)
- What happens if a target file already exists (e.g., new layout already populated)? (Migration does not overwrite; the existing file wins.)

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The default trust directory MUST resolve to `hosts` (relative) or `<data-dir>/hosts`, never to a path nested under `certs/`.
- **FR-002**: The default purgatory directory MUST resolve to `purgatory` (relative) or `<data-dir>/purgatory`, never to a path nested under `certs/`.
- **FR-003**: The machine's own certificate and key MUST live in an `identity/` directory as `<hostname>.crt` and `<hostname>.key`, replacing the `certs/certs/` and `certs/private/` layout.
- **FR-004**: Explicit `--trust-dir` and `--purgatory-dir` flags MUST continue to override the defaults.
- **FR-005**: A migration routine MUST automatically move files from the legacy `certs/` layout to the new flat layout, MUST be non-interactive, MUST be idempotent, MUST remove empty legacy directories, and MUST NOT overwrite existing files in the new layout.
- **FR-006**: The identity certificate's filename MUST be derived from the hostname so that it can be shared to a peer's trust directory under the existing `<hostname>.crt` convention.
- **FR-007**: Installation MUST generate the identity certificate/key in the new layout and MUST NOT create the legacy `certs/` directories.

### Key Entities *(include if feature involves data)*

- **Data directory**: the base directory (`DIR`) from which all runtime paths derive.
- **Identity**: our own certificate (`identity/<hostname>.crt`) and key (`identity/<hostname>.key`); the certificate is the file shared with peers for trust.
- **Trust store**: `hosts/` — trusted peer certificates named `<hostname>.crt`.
- **Purgatory**: `purgatory/` — captured unknown peer certificates named `<hostname>.<fingerprint>.crt`.
- **Legacy layout**: the old `certs/` tree (`certs/hosts`, `certs/purgatory`, `certs/certs/`, `certs/private/`) that the migration moves away from.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A fresh install contains `identity/<hostname>.crt` and `identity/<hostname>.key` and no `certs/` directory.
- **SC-002**: No default path in the program resolves under `certs/` (trust, purgatory, or identity).
- **SC-003**: A legacy install is migrated to the new layout automatically with zero prompts and with all empty legacy directories removed.
- **SC-004**: All existing end-to-end tests (trust exchange, capture, promotion) pass unchanged after the layout change.
- **SC-005**: Re-running the migration after completion is a no-op (idempotent) with no file changes.

## Assumptions

- The key lives flat in `identity/` next to the certificate (`identity/<hostname>.key`), matching the "not nested" request; key permissions remain restrictive.
- Migration runs automatically at program startup and during install, in addition to being available as a standalone helper.
- Legacy paths are only migrated when they match the known old defaults and are not explicitly overridden by the user.
- The hostname used for the identity filename is the same one used for the certificate CN and for peer trust naming.
