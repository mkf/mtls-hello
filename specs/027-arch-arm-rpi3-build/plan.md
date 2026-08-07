# Implementation Plan: Arch Linux ARM (RPi 3 Model B v1.2) Cross-Compilation Build Flow

**Branch**: `027-arch-arm-rpi3-build` | **Date**: 2026-08-07 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/027-arch-arm-rpi3-build/spec.md`

## Summary

Adds a new build flow that produces an Arch Linux ARM package (`mtls-hello-<v>-1-armv7h.pkg.tar.zst`) for the Raspberry Pi 3 Model B v1.2 (BCM2837 ARMv7-A, Cortex-A53). The build runs in an ephemeral Docker container with a pure-archlinux base; `makepkg -s` resolves `makedepends` (cross-toolchain, LDC, dub, go, etc.) inside. Cross-compilation is driven via `--target=armv7-unknown-linux-gnueabihf` (LDC) and `GOARCH=arm GOARM=7 CGO_ENABLED=0` (for the NNCP Go programs). The output is consumed by a `just package-arch-arm-rpi3` recipe and by a CI matrix job that co-ships the artifact alongside the existing `.deb` and native-arch packages.

## Technical Context

**Language/Version**: D (LDC).

**Primary Dependencies**: LDC1 with `--target=armv7-unknown-linux-gnueabihf`; Go (`scripts/build-nncp.sh` builds NNCP single-binary from source) with `GOARCH=arm GOARM=7 CGO_ENABLED=0`; `makepkg -s` (from arch's `pacman` package) for build-time dep resolution + final assembly; `arm-linux-gnueabihf-{gcc,binutils,glibc,linux-api-headers}` from arch's `extra` repo; zstd for compression; tar; bash.

**Storage**: filesystem — PKGBUILD template at `docker/pkgbuilds/mtls-hello.PKGBUILD`, pkgroot in `/build/pkg/` inside container, output at host's `dist/`.

**Testing**: qemu-arm-static + binfmt-M (for in-container install + execution smoke test); PKGINFO validation via `tar -xOf .pkg.tar.zst .PKGINFO`; ELF arch validation via `file`; byte-equivalence reproducibility via `sha256sum` of payload members across two builds.

**Target Platform**: Raspberry Pi 3 Model B **v1.2** (BCM2837 SoC, ARMv7-A, Cortex-A53, hard-float). Target OS: Arch Linux ARM, `arch=armv7h`. Builds run FROM x86_64 Linux with Docker.

**Project Type**: build-system / packaging (Dockerfile + shell scripts + justfile recipe). The cross-build flow does NOT add new runtime functionality — it produces the same artifact the native flow does, just for armv7h via cross-compile.

**Performance Goals**: SC-006 — full cross-build completes in under 30 minutes on a typical 2-vCPU/8 GB CI runner. Peak RAM inside the build container expected < 4 GB (g++ + LDC + dub + go compile of a small D daemon + tiny Go program). Most of the time is spent in pacman downloading `makedepends` on first run; subsequent runs with cached pacman drop into the 5–15 minute range.

**Constraints**:
- **Hermetic** — the cross-build MUST run in a container; host toolchain MUST NOT be required. (FR-008)
- **Reproducible** — `SOURCE_DATE_EPOCH` is set from the git commit time, not the wall clock — `makedepends` are me-tested for deterministic tar ordering; no host `rm -rf` / `find -delete`. (FR-009 + G1)
- **No bundled runtime deps** — Apache, bash, openssl, git, etc. are declared in PKGINFO `depend =` lines, not stuffed into the package. The user's correction 2026-08-07 explicitly required this. (FR-006)
- **RPi 3 Model B v1.2 strict** — `arch=armv7h` (hard-float); never `armv6` (Pi Zero W) or `aarch64` (Pi 4 / Pi 5).
- **Cross-compile build, not cross-compile install** — Apache on the target IS installed from Arch ARM repos via `pacman -U`'s automatic dep resolution.

**Scale/Scope**: One justfile recipe + one Dockerfile + one PKGBUILD + one ~80-line `scripts/package-arch-rpi3.sh`. Optional CI matrix job (idempotent — only runs in workflow). Total non-test source additions: ~200 lines.

## Constitution Check

*GATE: must pass before Phase 0 research. Re-check after Phase 1 design.*

Constitution at `.specify/memory/constitution.md` is the **placeholder template** — no project principles ratified yet. De-facto gates established by features 001–026 apply:

| Gate | Status | Notes |
|------|--------|-------|
| **G1**: no `rm -rf` / `rm -f` / `find -delete` | PASS | The cross-build's host-side orchestration depends only on `just`, `docker`, `tar`. Inside the container, `cleanup_pkgroot()` (from `scripts/package-common.sh`) uses anchored paths + `remove_file_safe` + `rmdir`. The new `scripts/package-arch-rpi3.sh` will reuse the same helpers — no new `rm -rf` introduced. |
| **G2**: no hardcoded data-dir defaults in library code | PASS | This is a packaging/packaging-script feature; it does NOT add library code. The package's data-dir convention (`/var/lib/mtls-hello/`) is the OS-level default and is set in the package payload layout (path-name only, not a runtime sentinel). |
| **G3**: host binaries with cleared `LD_LIBRARY_PATH` | PASS | The new shell scripts (`scripts/package-arch-rpi3.sh`, justfile recipe) run on the host; they `unset LD_LIBRARY_PATH` early (matching `scripts/sync-common.sh`, `scripts/sync-test.sh` pattern). Inside the container, the existing convention applies. |
| **G4**: `set -euo pipefail` strict mode | PASS | All new shell scripts will use strict mode. PKGBUILD is BASH-syntax anyway. |
| **G5**: shellcheck clean (severity ≥ warning) | PASS | Build-time-only; shellcheck will be applied to `scripts/package-arch-rpi3.sh` and the justfile recipe. Dockerfiles are exempt (linted separately if at all). |
| **G6**: spec-kit workflow followed | PASS | This document is the plan artifact for the `/speckit.plan` step, preceded by `/speckit.specify` which produced the spec, with `/speckit.tasks` and `/speckit.implement` to follow. |
| **G7**: externally observable behavior unchanged | PASS | The new build flow is additive — no change to the project binary's runtime behavior, handler responses, or storage layout at the application layer. Only the **distribution** surface gains a new arch. |
| **G8**: no new runtime dependencies | PASS | The cross-build adds **build** dependencies only (makedepends, all inside the container). **Runtime** deps are added to the package's PKGINFO `depend =` (FR-006) but those are existing Arch packages — no new runtime tools. |
| **G9**: one authoritative definition per shared concern | PASS | Cross-compile logic lives in ONE new file: `scripts/package-arch-rpi3.sh`. It reuses `build_binary()`, `stage_install_tree()`, `project_version()`, `project_description()` from existing `scripts/package-common.sh` (single source of truth from feature 012). No duplication. |
| **G10**: `specs/` excluded from line-count metrics | PASS | This feature adds spec docs; the implementation metrics in `quickstart.md` count only the new Dockerfile + `scripts/package-arch-rpi3.sh` (estimated ~200 LoC). |

## Project Structure

### Documentation (this feature)

```text
specs/027-arch-arm-rpi3-build/
├── plan.md                ← this file (/speckit.plan output)
├── research.md            ← Phase 0 output
├── data-model.md          ← Phase 1 output
├── quickstart.md          ← Phase 1 output
├── contracts/
│   ├── build-invocation.md   Phase 1 output
│   └── pkg-format.md         Phase 1 output
├── checklists/
│   └── requirements.md       (16/16 PASS from earlier /speckit.specify)
└── tasks.md              ← Phase 2 output (/speckit.tasks command - NOT created here)
```

### Source Code (repository root)

```text
docker/
├── Dockerfile.arch              (existing, native x86_64 — UNCHANGED)
├── Dockerfile.arch-rpi3          (NEW: cross-compile for armv7h)
└── pkgbuilds/
    └── mtls-hello.PKGBUILD     (NEW: macpacman-parsable manifest)

scripts/
├── package-arch.sh          (existing native x86_64 — UNCHANGED)
├── package-arch-rpi3.sh     (NEW: cross-compile wrapper)
├── package-common.sh        (existing shared helpers — UNCHANGED, reused as-is)
├── package-debian.sh        (unchanged)
├── package.sh               (unchanged)
└── build-nncp.sh            (existing — invoked with GOARCH=arm GOARM=7)

justfile                     (NEW recipe: package-arch-arm-rpi3)
.github/workflows/ci.yml     (NEW job: package-arch-arm-rpi3 with armv7h artifact path)

AGENTS.md                    (UPDATED: pointer flipped to this plan)
```

**Structure Decision**: This is a packaging/build-system feature, so the layout follows the **Option 1 (single project)** shape but adapted for build-system artifacts. The two "source trees" of note are:
1. `docker/Dockerfile.arch-rpi3` + `docker/pkgbuilds/*.PKGBUILD` — the build environment
2. `scripts/package-arch-rpi3.sh` + `justfile` recipe — the build driver

Both compose with the existing `scripts/package-common.sh` helpers (no duplication).

## Complexity Tracking

> **Fill ONLY if Constitution Check has violations that must be justified**

No Constitution gates have violations. All ten gates pass; no tracking needed.

One implementation note worth capturing here:

- This feature introduces ONE new Dockerfile (separate from the existing `Dockerfile.arch`) and ONE new justfile recipe. This is **not** a 2nd/3rd project — the existing native arch build (option 1 above) is preserved as-is for x86_64.
- The cross-architecture logic is corralled inside ONE shell script (the `scripts/package-arch-rpi3.sh` wrapper) so it doesn't bleed across the existing `package-arch.sh` file.
- The PKGBUILD is its own little file; it is mandatory for `makepkg -s` semantics. Files kept under `docker/pkgbuilds/` (new directory) so they don't pollute `scripts/`.
