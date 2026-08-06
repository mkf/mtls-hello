# Implementation Plan: Battery-Efficient Discovery

**Branch**: `019-battery-efficient-discovery` | **Date**: 2026-08-06 | **Spec**: `specs/019-battery-efficient-discovery/spec.md`

**Input**: Feature specification from `/specs/019-battery-efficient-discovery/spec.md`

## Summary

Replace the 100 ms polling loop in the discovery daemon's capture worker with an event-driven wake mechanism. The multicast listener thread will signal the worker only when a new capture request is enqueued, allowing the CPU to sleep while no peers are present. The implementation must first measure the baseline idle CPU usage to confirm the polling loop is the dominant consumer, then implement the change, and finally verify the idle CPU reduction.

## Technical Context

**Language/Version**: D (LDC 1.27 / D frontend 2.097), with `vibe-core` and `vibe-stream:tls` from dub.

**Primary Dependencies**: `vibe-core` (event loop and task scheduling), `vibe-stream:tls` (outbound TLS for peer capture), D standard library (`std.socket`, `std.process`, `core.sync`, `core.thread`).

**Storage**: In-memory capture queue; file system for purgatory and trust directories (unchanged).

**Testing**: D unit tests (`just test-d`), Robot Framework end-to-end tests (`just robot`), and filtered BATS tests (`just test --filter ...`).

**Target Platform**: Linux x86_64 (openSUSE Tumbleweed, Debian, Arch). The daemon runs as a user-level systemd service or ad-hoc process.

**Project Type**: System daemon / CLI discovery tool with Apache-backed HTTPS endpoints.

**Performance Goals**: Near-zero CPU usage when idle; peer capture latency under 2 seconds after a peer announcement.

**Constraints**: No platform-specific power APIs; no busy waits or spinlocks; clean shutdown on SIGINT/SIGTERM; preserve existing capture/callback behavior.

**Scale/Scope**: Single daemon per host, LAN multicast group, low-frequency peer events (human time scale, not high throughput).

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Gate | Description | Status | Notes |
|------|-------------|--------|-------|
| G1 | Spec contains no implementation details (languages, frameworks, APIs) | PASS | Spec describes behavior and constraints without prescribing a D primitive. |
| G2 | Feature is testable with measurable success criteria | PASS | Success criteria include idle CPU usage and peer capture latency. |
| G3 | Change is minimal and does not introduce unnecessary complexity | PASS | Only the capture worker idle path changes; no new abstractions. |
| G4 | Existing contracts (capture, callback, purgatory) remain unchanged | PASS | Spec explicitly states the callback contract and purgatory behavior are preserved. |
| G5 | Measure before optimizing | PASS | Spec requires a baseline CPU measurement before the fix. |

## Project Structure

### Documentation (this feature)

```text
specs/019-battery-efficient-discovery/
├── spec.md              # Feature specification
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/           # Phase 1 output
└── checklists/
    └── requirements.md  # Spec quality checklist
```

### Source Code (repository root)

```text
source/
├── app.d           # Main daemon: worker loop, signal handling
├── multicast.d    # Multicast listener, capture queue, request pushing
├── trust.d        # Peer certificate capture, fingerprinting, purgatory
└── version_.d     # Version string (generated)

tests/robot/
├── MtlsLibrary.py      # Robot Framework keyword library
└── mtls_hello.robot    # End-to-end tests

tests/
├── apache.bats         # Apache/CGI feature tests
└── smoke.bats          # Legacy end-to-end tests

scripts/
├── on-discover.sh      # Discovery callback
├── sync-common.sh      # Git sync helpers
├── merge-spool.sh      # Bundle spool merge
├── trust-host.sh       # Trust a host certificate
├── cgi-trust.sh        # CGI trust evaluation
├── cgi-capture.sh      # CGI purgatory capture
├── cgi-common.sh       # CGI helper functions
├── apache-config.sh    # Apache configuration generator
└── apache-port-helper.sh # Port discovery helper
```

**Structure Decision**: The feature is a focused change inside the existing D discovery daemon (`source/app.d` and `source/multicast.d`). No new directories or modules are needed; only the capture queue and worker synchronization logic are extended. The existing unit and Robot tests will be reused, with one additional Robot test for idle CPU behavior.

## Complexity Tracking

No constitution violations. The change is intentionally small and localized.

## Phase 0: Research

See `research.md` for the synchronization mechanism decision and alternatives.

## Phase 1: Design & Contracts

See `data-model.md`, `contracts/`, and `quickstart.md`.
