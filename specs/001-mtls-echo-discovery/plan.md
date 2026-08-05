# Implementation Plan: Mutual-TLS Echo Endpoint with LAN Discovery

**Branch**: `001-mtls-echo-discovery` | **Date**: 2026-08-05 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/001-mtls-echo-discovery/spec.md`

## Summary

A D-language HTTP service that serves each URL path as `text/plain` over a mutually authenticated TLS connection (server cert + required, CA-trusted client cert), and lets multiple service instances discover each other on a LAN via periodic UDP multicast announcements. The service is configurable at startup (port, certificate paths, discovery on/off). A Guix dev shell provides the real OpenSSL the host lacks (the host's LibreSSL breaks the OpenSSL bindings at link time).

## Technical Context

**Language/Version**: D — LDC 1.27.1 (frontend 2.097) via Guix; host also has DMD 2.112.1 / LDC 1.42.0 (host link fails on LibreSSL, so Guix is the build target).

**Primary Dependencies**: vibe-d 0.10.3 (vibe-http 1.5.1, vibe-core 2.14.0, vibe-stream 1.4.1), deimos `openssl` bindings 3.4.0, std.socket (phobos).

**Storage**: N/A — stateless HTTP service; no persistence.

**Testing**: BATS (`tests/smoke.bats`) for end-to-end HTTPS/mTLS behavior; shell script `scripts/gen_certs.sh` generates the test PKI.

**Target Platform**: Linux (x86_64), LAN-connected hosts. Deployed via `guix shell -f guix.scm`.

**Project Type**: web-service (HTTPS server, single binary).

**Performance Goals**: LAN-scale — a handful of instances, low request rate. No throughput target; startup and discovery latency are the only real timings (discovery within one announcement interval).

**Constraints**: Host `/usr/lib64` ships LibreSSL 4.2.1 (masquerades as OpenSSL 3.5.3) which lacks `ERR_new`/`ERR_set_error`/`ERR_add_error_data` — link fails. Must build inside Guix with real OpenSSL 3.0.7. Guix LDC defaults to `-fuse-ld=gold` but Guix binutils has no `ld.gold` → must pass `--linker=bfd`. Guix `gcc-toolchain` has no `cc` symlink → LDC needs a `cc` shim or explicit driver.

**Scale/Scope**: Single service module + single discovery module + BATS suite. ~250 lines of D.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

- `.specify/memory/constitution.md` is an unfilled template — no named principles or binding gates exist.
- **Result: PASS** (no gate violations possible). Re-checked after Phase 1: no new gates introduced; still PASS.

## Project Structure

### Documentation (this feature)

```text
specs/001-mtls-echo-discovery/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/           # Phase 1 output
│   ├── http.md          # HTTP + mTLS contract
│   ├── discovery.md     # Multicast wire protocol
│   └── cli.md           # Startup configuration contract
└── tasks.md             # Phase 2 output (/speckit.tasks — NOT created by /speckit.plan)
```

### Source Code (repository root)

```text
source/
├── app.d          # wiring: parse args → build TLS → build router → listen → start discovery
└── multicast.d    # discovery aspect: announce + listen (UDP multicast, JSON payloads)

tests/
└── smoke.bats     # e2e: no-cert rejected, untrusted-CA rejected, echo works, content-type

scripts/
└── gen_certs.sh   # generate CA + server + client certs + client.p12

guix.scm           # dev shell: dub, ldc, gcc-toolchain, openssl, pkg-config, curl, bats, nss-certs
justfile           # build / run / gen-certs / test / clean (all via guix shell)
dub.json           # package recipe (vibe-d:http ~>0.10.0)
dub.selections.json# pinned dependency versions
certs/             # generated test PKI (gitignored)
```

**Structure Decision**: Single D project (Option 1). Two source modules: `app.d` owns HTTP/TLS wiring, `multicast.d` owns the discovery concern. No models/services split needed at this scope.

## Complexity Tracking

> **Not applicable** — Constitution Check passed with no violations; no complexity justification required.
