# Implementation Plan: Per-Hostname Credential Store and Discovery Callback

**Branch**: `002-per-host-cert-hook` | **Date**: 2026-03-19 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/002-per-host-cert-hook/spec.md`

## Summary

Extend the mTLS echo server with per-hostname credential storage and a discovery callback hook. When a peer announces itself via multicast, the server executes an operator-provided script with environment variables identifying the peer (name, credential file path, connection address). The script includes a utility function for issuing authenticated requests to the peer's endpoints using the local private credential and the peer's public credential for server verification (certificate pinning).

## Technical Context

**Language/Version**: D — LDC 1.27.1 (frontend 2.097) via Guix; host also has DMD 2.112.1 / LDC 1.42.0 (host link fails on LibreSSL, so Guix is the build target).

**Primary Dependencies**: vibe-d 0.10.3 (vibe-http 1.5.1, vibe-core 2.14.0, vibe-stream 1.4.1), deimos `openssl` bindings 3.4.0, std.socket (phobos), std.process (phobos, for `spawnProcess`).

**Storage**: Filesystem — per-hostname certificate files under `certs/hosts/<hostname>.crt`. No database.

**Testing**: BATS (`tests/smoke.bats`) for end-to-end HTTPS/mTLS, script execution, and authenticated request helper behavior. Discovery callback test skips on loopback-only hosts (environmental limitation — same as 001's discovery test).

**Target Platform**: Linux (x86_64), LAN-connected hosts. Deployed via `guix shell -f guix.scm`.

**Project Type**: web-service (HTTPS server, single binary) with operator-provided shell callbacks.

**Performance Goals**: LAN-scale — a handful of instances, low request rate. Callback script execution is non-blocking (spawned process, server continues serving). No throughput constraints.

**Constraints**: Same Guix/LDC/OpenSSL build constraints as feature 001 (see `specs/001-mtls-echo-discovery/research.md`). Script execution must not block the event loop (use `spawnProcess`, not `execute`). The multicast discovery callback path cannot be tested on loopback-only hosts (lo lacks MULTICAST) — test verification relies on a LAN-capable interface or the test is skipped.

**Scale/Scope**: Extends source/multicast.d with hostname announcement, callback dispatch, and credential lookup. New scripts/on-discover.sh default callback + helper. ~100 additional lines of D, ~30 lines of bash.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

- `.specify/memory/constitution.md` is an unfilled template — no named principles or binding gates exist.
- **Result: PASS** (no gate violations possible). Re-checked after Phase 1: no new gates introduced; still PASS.

## Project Structure

### Documentation (this feature)

```text
specs/002-per-host-cert-hook/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/           # Phase 1 output
│   ├── discovery.md     # Updated multicast wire protocol (host field, callback trigger)
│   ├── cli.md           # Updated startup configuration (new options)
│   └── callback.md      # Script contract — env vars, utility function spec
└── tasks.md             # Phase 2 output (/speckit.tasks — NOT created by /speckit.plan)
```

### Source Code (repository root)

```text
source/
├── app.d               # wiring: parse args → build TLS → route → listen → start discovery
└── multicast.d         # discovery: announce + listen + credential lookup + callback spawn

scripts/
├── gen_certs.sh        # PKI generation (existing, may be extended for per-host certs)
└── on-discover.sh      # NEW: default discovery callback + mtls_curl helper

certs/
└── hosts/              # NEW: per-hostname credential store
    └── <hostname>.crt  # peer's public certificate (operator pre-provisioned)

tests/
└── smoke.bats          # extended: callback + helper tests
```

**Structure Decision**: Same single-binary layout as feature 001. New files: `scripts/on-discover.sh` (default callback), `certs/hosts/` (credential store). `source/multicast.d` gains credential lookup and callback dispatch. `source/app.d` gains CLI parsing for new options.

## Complexity Tracking

> No constitution violations. No complexity justifications required.
