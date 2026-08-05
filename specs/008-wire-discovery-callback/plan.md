# Implementation Plan: Wire Discovery Callback

**Branch**: `008-wire-discovery-callback` | **Date**: 2026-08-05 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/008-wire-discovery-callback/spec.md`

## Summary

Modify the multicast discovery worker to actually invoke `scripts/on-discover.sh` when a peer is discovered. Add a `host` field to multicast announcements. Make the callback script path configurable via `CALLBACK_SCRIPT` env var. Include `on-discover.sh` in `just install`.

## Technical Context

**Language/Version**: D (LDC2 1.27+, vibe.d 0.10.x)

**Primary Dependencies**: vibe.d (HTTP server), `std.process` (subprocess spawning), `std.socket` (UDP multicast)

**Storage**: N/A — read-only from server process environment and trust directory

**Testing**: BATS — simulate discovery via UDP packets; verify callback spawn and announcement contents

**Target Platform**: Linux with multicast-enabled network interface

**Project Type**: Fix/enhancement — 3 files changed (`source/multicast.d`, `source/app.d`, `scripts/install.sh`)

**Performance Goals**: Callback spawn <10ms; announcement payload ~60 bytes

**Constraints**: Callback must not block the multicast receive loop

**Scale/Scope**: ~70 lines across 3 files; 4-5 new BATS tests

## Constitution Check

The project constitution is a template with no concrete principles. **PASS** by default.

## Project Structure

### Documentation

```text
specs/008-wire-discovery-callback/
├── plan.md, research.md, data-model.md, quickstart.md
├── contracts/ (discovery.md, callback.md)
└── tasks.md
```

### Source Changes

```text
source/multicast.d    # +hostName/trustDir to config, +host in announcement, +spawn callback
source/app.d           # +read HOST_NAME/CALLBACK_SCRIPT from env, pass to multicast
scripts/install.sh     # +copy on-discover.sh to ~/.local/share/mtls-hello/scripts/
tests/smoke.bats       # +4-5 new tests
```

## Complexity Tracking

No violations. No entries.
