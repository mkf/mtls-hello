# Implementation Plan: Codebase Simplification

**Branch**: `026-codebase-simplification` | **Date**: 2026-08-07 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/026-codebase-simplification/spec.md`

## Summary

Simplify the mtls-hello codebase by consolidating duplicated shell logic, removing dead code, and extracting shared helpers — while preserving every externally observable behavior from specs 001–025. The D daemon (898 lines) is already lean; the primary target is the ~2,800 lines of shell scripts and ~500 lines of CGI handlers where copy-paste duplication and inconsistent path-resolution patterns have accumulated across 25 features.

## Technical Context

**Language/Version**: D (LDC 1.27.1) for the discovery daemon; Bash (POSIX-ish, `set -euo pipefail`) for all scripts/handlers/CLI.

**Primary Dependencies**: vibe.d (D HTTP/TLS/multicast runtime); Apache httpd with mod_ssl/mod_dav/mod_cgi (HTTP serving); OpenSSL 3.x (cert generation, fingerprinting); git (bundle sync); coreutils b2sum/base32/xxd (NNCP key derivation).

**Storage**: Filesystem under `--data-dir`: `identity/`, `hosts/`, `purgatory/`, `drop/`, `nncp/queues/`, `scripts/on-discovery.d/`.

**Testing**: BATS (5 files, 92 tests); Robot Framework (3 files, 5 tests); D unit tests (test_main.d).

**Target Platform**: Linux (openSUSE Tumbleweed-Slowroll dev; Debian/Arch CI packages).

**Project Type**: System service — D daemon (multicast discovery + outbound cert capture) + Apache httpd (HTTPS endpoints) + CGI handlers (bash).

**Constraints**: No `rm -rf`/`find -delete` anywhere (G1); host binaries run with `LD_LIBRARY_PATH` cleared; Nix binaries keep Nix env; no hardcoded defaults for data-dir; externally observable behavior must not change.

**Scale/Scope**: ~4,600 lines D+shell (excluding specs/tests); 25 prior feature specs; 92 BATS tests + 5 Robot tests must remain green.

## Constitution Check

*Constitution file is a placeholder template (no ratified principles). De-facto gates from features 001–025 apply:*

| Gate | Status | Notes |
|------|--------|-------|
| G1: No `rm -rf`/`rm -f`/`find -delete` | PASS | Simplification uses plain `rm` + `rmdir` on anchored paths only |
| G2: No hardcoded data-dir defaults in library code | PASS | Scripts use `DATA_DIR="${DATA_DIR:-…}"` with `$HOME` fallback only in install.sh |
| G3: Host binaries run with cleared `LD_LIBRARY_PATH` | PASS | Test invocations preserve this pattern |
| G4: `set -euo pipefail` in all shell scripts | PASS | Consolidation preserves strict mode |
| G5: Shellcheck clean (severity ≥ warning) | PASS | New/merged scripts pass shellcheck |
| G6: Spec-kit workflow followed | PASS | This plan |
| G7: Externally observable behavior unchanged | PASS | Regression oracle: full test suite |
| G8: No new runtime dependencies | PASS | Consolidation removes code, not adds tools |
| G9: One authoritative definition per shared concern | **TARGET** | This is the simplification's success criterion (SC-004) |
| G10: `specs/` excluded from line-count metrics | PASS | Assumptions section documents this |

## Project Structure

### Source Code (repository root)

```text
source/
├── app.d              # D daemon entry (unchanged: 233L)
├── multicast.d        # D multicast + capture queue (unchanged: 366L)
├── trust.d            # D trust + purgatory (unchanged: 289L)
├── test_main.d        # D unit tests (unchanged)
└── version_.d         # Auto-generated version string

scripts/
├── cgi-lib.sh         # MERGED: cgi-common.sh + cgi-trust.sh (was 297L → ~250L)
├── cleanup-common.sh  # Unchanged (90L)
├── sync-lib.sh        # MERGED: sync-common.sh + sync-state.sh + sync-test.sh (was 302L → ~220L)
├── apache-config.sh   # Minor: use data_dir_resolve helper
├── gen-certs.sh       # Unchanged (174L — feature 025 validated)
├── build-nncp.sh      # Unchanged (339L)
├── install.sh         # Updated source references
├── install-service.sh # Unchanged
├── log-capture.sh     # Use shared CN extraction
├── trust-host.sh      # Use shared CN extraction
├── merge-spool.sh     # Updated source references
├── migrate-layout.sh  # Unchanged
├── package*.sh        # Minor: updated source references
└── on-discovery.d/    # 90-log.sh DATA_DIR bug fixed; 00/10 use shared data_dir_resolve

handlers/              # Each handler simplified via cgi_require_trusted()
├── hello.get.sh       # 21L → ~12L
├── cert-echo.get.sh   # 48L → ~30L
├── head.get.sh        # 40L → ~25L
├── bundle.post.sh     # 49L → ~35L
├── spool.get.sh       # 40L → ~25L
├── drop-proxy.sh      # 166L → ~130L (use cgi_require_trusted + shared helpers)
└── nncp-receive.post.sh # 125L → ~100L

cli/                   # Already well-factored, minor cleanup only

# REMOVED:
# scripts/docker-discovery-test.sh  (dead code — orphan)
```

**Structure Decision**: Flatten the two-file CGI library into one (`cgi-lib.sh`); merge three sync scripts into one (`sync-lib.sh`); remove the orphan `docker-discovery-test.sh`. No structural changes to D code or directory layout.

## Complexity Tracking

No constitution violations to justify. All gates pass.
