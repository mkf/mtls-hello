# Contract: Build Invocation (`just package-arch-arm-rpi3`)

**Date**: 2026-08-07
**Feature**: 027-arch-arm-rpi3-build

This contract describes how the user invokes the cross-build, what the build does, and what artifacts are produced. It is the user-visible surface of the build flow.

## Invocation surface

### Justfile recipe

```makefile
package-arch-arm-rpi3: dist/
    docker build -f docker/Dockerfile.arch-rpi3 -t mtls-hello-arm-rpi3-build .
    docker run --rm \
        -v "$(CURDIR):/src" \
        -v "$(CURDIR)/dist:/out" \
        -e TAG=$(if $(GIT_TAG),$(GIT_TAG),v0.0.0-$(shell git rev-parse --short HEAD)) \
        mtls-hello-arm-rpi3-build
    # Optional in-container smoke test (qemu-arm-static + chroot).
    @just _test-arm-rpi3-package dist/mtls-hello-*-armv7h.pkg.tar.zst
```

### CLI form (for CI / no-just callers)

```bash
docker build -f docker/Dockerfile.arch-rpi3 -t mtls-hello-arm-rpi3-build ./
docker run --rm \
    -v "$REPO_ROOT:/src:ro" \
    -v "$REPO_ROOT/dist:/out" \
    -e GIT_TAG=vX.Y.Z-1 \
    mtls-hello-arm-rpi3-build
```

## Input contract

### Files expected at `/src` inside the container

| Path | Purpose | Required? |
|------|---------|-----------|
| `dub.json` | reads version (`project_version()`) | yes |
| `source/app.d` and friends | dub build target | yes |
| `scripts/` (whole tree) | package + build scripts | yes |
| `handlers/`, `cli/` | ship inside package | yes |
| `config/apache-site.conf.in` | ship inside package | yes |
| `justfile` (NOT used inside the container) | for host-side driver | no |

The container makes its own writable copy at `/build` before any work begins, so `/src` doesn't need write access.

### Environment variables (host → container)

| Var | Default | Effect |
|-----|---------|--------|
| `GIT_TAG` | `v0.0.0-${SHORT_SHA}` if unset | controls `${pkgver}` substitution |

## Output contract

### File emitted to `/out`

A single file named `mtls-hello-${VER}-1-armv7h.pkg.tar.zst` (e.g., `mtls-hello-0.13.2-1-armv7h.pkg.tar.zst`).

The host should mount `/out` to a directory it owns (typically `$REPO_ROOT/dist/`). The path on the host maps directly — `ls dist/` will list the package after `just` exits 0.

### Exit code semantics

| Container exit code | Meaning | Justfile behavior |
|---------------------|---------|-------------------|
| 0 | success — package emitted | continue to optional test step |
| non-zero | failure — logged to stderr by makepkg | abort |
| specific sub-codes | (same as makepkg) | propagated |

### Side effects

- Container is removed automatically (`--rm`).
- `dist/` directory fills with new artifact *or* retains previous artifacts (cleanup is host's responsibility).
- pacman cache may grow on host if `/var/cache/pacman/pkg` is mounted (caching is fine; use `--rm` plus `--volume` for cache).

## Validation recipe

Once `just package-arch-arm-rpi3` exits 0, the user can verify (on x86_64 host):

```bash
# PKGINFO declares arch=armv7h
tar -xOf dist/mtls-hello-*-armv7h.pkg.tar.zst '.PKGINFO' | grep '^arch ='

# ELF reports ARMv7
tar -xOf dist/mtls-hello-*-armv7h.pkg.tar.zst 'usr/bin/mtls-hello' \
    > /tmp/m 2>/dev/null
file /tmp/m
# expected: ELF 32-bit LSB executable, ARM, ...

# Same for NNCP programs
tar -xOf dist/mtls-hello-*-armv7h.pkg.tar.zst 'var/lib/mtls-hello/bin/nncp-toss' \
    > /tmp/n 2>/dev/null
file /tmp/n
# expected: ELF 32-bit LSB executable, ARM, ...
```

## Failure modes

| Symptom | Cause | Fix |
|---------|-------|-----|
| `pacman: unable to resolve dependency` for `arm-linux-gnueabihf-gcc` | toolchain not in container | check `makedepends =` ordering; ensure Arch Linux's `multilib`/`core` repos enabled |
| `ldc2: unrecognized --target arch armv7` | LDC version too old | bump `ldc` in makedepends; min LDC 1.27 supports armv7 |
| `go: cannot find GOROOT` | Go not available (we're cross; need to install it) | add `go` to makedepends, or skip NNCP for this build (FR-007 forbids this) |
| Binary executes but `Illegal instruction` on the target | wrong arch-flavor / hard-float mismatch | verify `--target=armv7-unknown-linux-gnueabihf`; check `GOARM=7` |
| Build takes >30 min on a CI runner | package builds natively instead of cross-compiling | check that `LDCFLAGS`/`ldc2 --target` propagate through dub |
