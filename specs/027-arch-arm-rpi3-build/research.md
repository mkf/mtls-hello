# Research: Arch Linux ARM (RPi 3 Model B v1.2) Cross-Compilation Build Flow

**Date**: 2026-08-07
**Feature**: 027-arch-arm-rpi3-build

## Methodology

Five unknowns identified in the spec's Technical Context that need resolution:

1. LDC cross-compile flag for armv7h
2. Go cross-compile env vars for armv7h (the NNCP programs)
3. Pacman dependency-resolution pattern (`makepkg -s` semantics vs hand-rolled tar+zstd)
4. Apache runtime as declared dep — should we *not* bundle it
5. qemu-arm-static test pattern on x86_64 host

Each resolved below.

---

## R1. LDC1 cross-compile target triple for armv7h

**Decision**: Use `ldc2 --target=armv7-unknown-linux-gnueabihf` (note the hf suffix).

**Rationale**: LDC's upstream target list for ARM uses the architecture tag `armv7` (not `armv7h`). The `hf` suffix tells the linker to use hard-float ABI. Without `hf`, the produced binary would refuse to start on a hard-float distro (anything Arch Linux ARM since ca. 2015). The dub invocation in `scripts/package-common.sh` already uses a generic `dub build` — we need to extend `build_binary()` (or wrap it) to accept a target override via env var.

**Alternatives considered**:
- `arm-unknown-linux-gnueabihf` (without `v7`) → produces generic armv6/v7 soft/hard-float mix; works on RPi 3 but wastes FPU, generates extra flags per call site. Rejected: RPi 3 Model B v1.2 has hard-float and we should advertise it.
- `armv7a-unknown-linux-gnueabihf` ('a' for ARMv7-A architecture) → equivalent on Cortex-A53. Rejected: minor-flag difference; `armv7` is the upstream-default spell.

---

## R2. Go cross-compile for armv7h (NNCP programs)

**Decision**: Set `GOARCH=arm GOARM=7` (note: 7 = ARMv7 + soft-float flag is wrong; hard-float is selected at link-time via libc, `GOARM=7` means ARMv7 with VFPv3-D32, which matches Cortex-A53).

**Rationale**: `GOARM` is a single-digit code for ARMv7 sub-features (5/6/7); 7 = VFPv3 + NEON. The hard/soft-float ABI is determined by *which libc* the binary is linked against — we link against `arm-linux-gnueabihf-glibc`, so the produced binary is hard-float by construction. No `GOARM=7hf` style exists; `GOARM=7` is enough.

**Alternatives considered**:
- `GOARM=6` (VFPv2) → RPi 3 has VFPv3, but VFPv2 baseline ensures broad compatibility. Rejected: loses NEON at compile time, slower on the Pi, no benefit.
- CGO cross-compile with `CC=arm-linux-gnueabihf-gcc` → required if any NNCP dep is cgo. Rejected as default: NNCP is pure-Go (no cgo). CGO only needs to be left disabled: `CGO_ENABLED=0`.

---

## R3. Pacman `makepkg -s` semantics vs. the project's existing tar+zstd pattern

**Decision**: **Use `makepkg -s`** inside the container. The existing `scripts/package-arch.sh` does *not* use makepkg — it directly invokes `tar | zstd` — but the user has clarified (manual correction 2026-08-07) that dependencies should be resolved the Arch way (`makepkg -s` auto-installs `makedepends`). 

**Rationale**: Two reasons to switch:
1. **Spec FR-013** requires `makepkg -s` so `makedepends` are auto-installed via pacman inside the container. The current pattern bypasses this; the container's `Dockerfile.arch-rpi3` would need to embed every build-tool package explicitly, making it longer and harder to maintain.
2. **Spec FR-006** requires `makedepends =` to be properly declared — that field is meaningful only when paired with a `.PKGBUILD` parsed by makepkg. Hand-rolled tar+zstd doesn't read .PKGBUILD at all, so the field would be comment-only.

**Implementation**: introduce a thin `PKGBUILD` template at `docker/pkgbuilds/mtls-hello.PKGBUILD` (rendered per-build). Existing `build_binary()`/`stage_install_tree()` from `scripts/package-common.sh` continues — they're language-agnostic — but they now run via `makepkg` orchestration and write to a `pkg/` directory that makepkg tar+zstds for us. The previous tar+zstd hand-rolled path is preserved as a fallback for non-makepkg invocations (e.g., the user's CI matrix that already inlines `archive ../dist`).

**Alternatives considered**:
- **Keep tar+zstd, embed expanded `makedepends` in container's pacman install line**: Rejected — the user explicitly asked for makepkg-s semantics. Also defeats the point of declaring deps.
- **Use `makepkg` without `-s`**: Rejected — `-s` is the part that auto-installs makedepends. Without it, the container would still need every build dep pre-baked.

---

## R4. Apache runtime handling — declare as `depend`, do NOT bundle

**Decision**: Apache httpd is **declared** in PKGINFO `depend =` (`depend = apache`) but **not bundled** in the `.pkg.tar.zst`. Same for `bash`, `openssl`, `git`, `coreutils`, `findutils`, `grep`, `sed`, `awk`, and `glibc`. The `arm-linux-gnueabihf-glibc` *runtime linker* itself is NOT bundled either — the Arch ARM `glibc` runtime ABI delivers it via `ld-linux-armhf.so.3`.

**Rationale**: Bundling Apache into the package would duplicate ~5 MB of files Arch already provides; if Apache gets a security update, the user would have to install a new mtls-hello to get it. Declaring it as a runtime `depend` is what the user explicitly requested (correction 2026-08-07).

**Alternatives considered**:
- Bundle Apache + a launcher script that prefers the bundled binary if present. Rejected: complexity, security concerns, contradicts arch packaging conventions.
- Fork Apache onto a separate -mtls-hello package and depend on *that*. Rejected: out of scope, adds a second package.

---

## R5. In-container testing without actual RPi 3 hardware

**Decision**: Use `qemu-arm-static` + binfmt_misc to chroot-test the produced package inside an Arch Linux ARM container on the x86_64 build host. This gives nearly identical coverage to actual hardware, without requiring CI runners have ARM boards.

**Rationale**: GitHub Actions runners are x86_64. Acquiring a RPi 3 specifically for CI is wasteful — `qemu-arm-static` + binfmt-M (5 ms startup cost per exec) lets us mount the produced package, run `pacman -U` against an Arch ARM chroot's package DB, then invoke `/usr/bin/mtls-hello --version` emulated. Real ARMv7 instructions run beneath the emulator; FPU emulation is exact (almost no JIT). This is the same approach Arch-ARM community uses for package smoke testing.

**Alternatives considered**:
- Static QEMU inside an x86_64 chroot. Weaker than binfmt because each invocation requires explicit `qemu-arm-static /path/to/binary` prefix.
- Skip in-container test entirely; rely on the user's bench hardware. Rejected: SC-002 (qa via qemu + chroot) requires automated verification, not ad-hoc.

---

## Summary table

| ID | Decision | Choosing over |
|----|----------|---------------|
| R1 | `--target=armv7-unknown-linux-gnueabihf` | armv6 generic; armv7a variant |
| R2 | `GOARCH=arm GOARM=7 CGO_ENABLED=0` | GOARM=6 (no NEON); cgo with arm cross-CC |
| R3 | makepkg -s, with PKGBUILD template | hand-rolled tar+zstd; makepkg without -s |
| R4 | declare Apache/bash/etc as `depend`, don't bundle | bundle Apache; fewer deps |
| R5 | qemu-arm-static + binfmt-m in CI | CI-bench hardware only; or plain chroot without emulator |

---

## Notes on the existing-art baseline

- Existing `scripts/package-arch.sh` + `scripts/package-common.sh` already implement the cross-cutting tar+zstd path. We re-use `build_binary()`, `stage_install_tree()`, `project_version()`, `project_description()` from `scripts/package-common.sh` (the work for feature 012). The cross-compile flow will add a new sibling script `scripts/package-arch-rpi3.sh` that:
  1. Wraps `build_binary()` with `ldc2 --target=...` override (via env) and `dub build --target=<ar>`
  2. Wraps `build_nncp()` (from `scripts/build-nncp.sh`) with `GOARCH=arm GOARM=7` env override
  3. Calls `makepkg -s` for the final assembly after staging in a `pkg/` dir via `stage_install_tree()`

- The Docker base image for the existing native arch build is `archlinux:latest`. For the cross build, we still use `archlinux:latest` (NOT `archlinux:armv7`) — we're cross-compiling FROM x86_64, so the base image doesn't need to be the target arch. The cross toolchain (`arm-linux-gnueabihf-*`) is installed via pacman inside this image.

- The existing `docker/Dockerfile.arch` is a starting point but the new file is `docker/Dockerfile.arch-rpi3` (kept separate so the existing x86_64 build flow doesn't regress).
