# Implementation Plan: Production-Ready Install & Systemd Service

**Branch**: `007-production-install-systemd` | **Date**: 2026-08-05 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/007-production-install-systemd/spec.md`

## Summary

Add a `just install` target that copies the compiled `mtls-hello` binary to `~/.local/bin` and handler scripts to `~/.local/share/mtls-hello/handlers/`. Add `--version`, `--port=0` (random ephemeral port), and `--port-file=PATH` flags to the server. Add a `just install-service` target that generates a systemd user service unit at `~/.config/systemd/user/mtls-hello.service`. The server binary itself requires only minor CLI additions; the bulk of the work is in the `justfile` and new shell scripts.

## Technical Context

**Language/Version**: D (LDC2 1.27+, vibe.d 0.10.x)

**Primary Dependencies**: vibe.d (HTTP server, TLS, logging), OpenSSL 3.x (via vibe-stream TLS)

**Storage**: Filesystem — `~/.local/bin/mtls-hello` (binary), `~/.local/share/mtls-hello/handlers/` (scripts), `~/.config/systemd/user/mtls-hello.service` (service unit), ephemeral port-file at `%t/mtls-hello.port`

**Testing**: BATS (bash automated testing system) with `just test` target

**Target Platform**: Linux with systemd user-instance support (systemd ≥ 226), OpenSSL 3.x at runtime

**Project Type**: CLI server binary with install/service orchestration via `justfile` + shell scripts

**Performance Goals**: N/A — install and service generation are one-shot operations; port-file write is negligible

**Constraints**: Installed binary must run without the Guix shell or source tree; host OpenSSL 3.x must be present (dynamically linked). Must not require root.

**Scale/Scope**: Single binary, single service unit, 2-3 new CLI flags, 2 new `just` targets, 1-2 new shell scripts

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

The project constitution is a template with no concrete principles filled in. No gates to evaluate. **PASS** by default.

## Project Structure

### Documentation (this feature)

```text
specs/007-production-install-systemd/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/           # Phase 1 output
│   ├── cli.md           # Updated CLI contract with new flags
│   └── install.md       # Install and service contract
└── tasks.md             # Phase 2 output (/speckit.tasks)
```

### Source Code (repository root)

```text
./
├── source/              # D source
│   ├── app.d            # CLI + server entry point (modified)
│   ├── handlers.d       # Script-executing HTTP handlers (unchanged)
│   ├── multicast.d      # Multicast discovery (unchanged)
│   └── trust.d          # Certificate trust (unchanged)
├── handlers/            # Default handler scripts (installed to ~/.local/share)
├── scripts/
│   ├── install.sh       # NEW: copy binary + handlers to ~/.local
│   └── install-service.sh # NEW: generate systemd user service unit
├── tests/
│   └── smoke.bats       # BATS tests (new install/service tests added)
├── justfile             # Build and install targets (modified)
├── dub.json             # D build config (modified: add version)
└── guix.scm             # Dev environment (unchanged)
```

**Structure Decision**: Single-project layout. Two new shell scripts handle install and service generation. The D source requires only minor CLI additions.

## Complexity Tracking

No violations — constitution is empty, project is simple. No entries.
