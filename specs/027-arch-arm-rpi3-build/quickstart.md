# Quickstart: Arch Linux ARM (RPi 3 Model B v1.2) Cross-Compilation Build Flow

**Date**: 2026-08-07
**Feature**: 027-arch-arm-rpi3-build

## Prerequisites

- **Linux host** (x86_64) with **Docker** installed.
- The repository checked out at any branch.
- (Optional, for the qemu verification step) `qemu-arm-static` and/or Docker's binfmt-M set up:
  ```bash
  docker run --rm --privileged docker/binfmt:a799690x2
  ```

## Build it

From the repository root:

```bash
just package-arch-arm-rpi3
```

This will:

1. Build the docker image `mtls-hello-arm-rpi3-build` from `docker/Dockerfile.arch-rpi3`.
2. Run the container with `$REPO_ROOT` mounted at `/src` (read-only), a writable copy made at `/build`, and `dist/` mounted at `/out`.
3. Inside the container, `makepkg -s` resolves `makedepends` (auto-installs `arm-linux-gnueabihf-*`, `ldc`, `dub`, `go`, etc.), then runs the cross-compile, then assembles the package.
4. After the container exits 0, the host finds `dist/mtls-hello-*-armv7h.pkg.tar.zst`.
5. (Optional) A qemu-arm-static chroot test step runs to validate that the package installs and the binary executes.

## Verify it (manual)

```bash
# 1. The package file exists.
ls -l dist/mtls-hello-*-armv7h.pkg.tar.zst

# 2. PKGINFO declares armv7h.
tar -xOf dist/mtls-hello-*-armv7h.pkg.tar.zst '.PKGINFO' | grep '^arch ='

# 3. The binary's ELF header says ARM.
tar -xOf dist/mtls-hello-*-armv7h.pkg.tar.zst './usr/bin/mtls-hello' \
    > /tmp/mtls-hello 2>/dev/null
file /tmp/mtls-hello

# 4. NNCP binaries likewise.
tar -xOf dist/mtls-hello-*-armv7h.pkg.tar.zst \
    './var/lib/mtls-hello/bin/nncp-toss' > /tmp/nncp-toss 2>/dev/null
file /tmp/nncp-toss
```

## Run it on a real RPi 3 Model B v1.2

```bash
# 1. Copy the package to the Pi.
scp dist/mtls-hello-*-armv7h.pkg.tar.zst alarm@pi3.lan:/tmp/

# 2. On the Pi, install Apache (provides also httpd + mod_ssl + mod_dav).
ssh alarm@pi3.lan -- 'sudo pacman -Syu --noconfirm apache'

# 3. Install the package.
ssh alarm@pi3.lan -- 'sudo pacman -U /tmp/mtls-hello-0.13.2-1-armv7h.pkg.tar.zst --noconfirm'

# 4. Generate the self-signed identity.
ssh alarm@pi3.lan -- 'sudo mtls-hello-install --gen-cert-only'

# 5. Enable the user-level systemd service.
ssh alarm@pi3.lan -- 'sudo -u alarm XDG_RUNTIME_DIR=/run/user/$(id -u alarm) systemctl --user enable --now mtls-hello'

# 6. Verify it's up.
ssh alarm@pi3.lan -- 'systemctl --user status mtls-hello'
# expected: active (running)
```

## Run it on qemu-arm-static (no Pi hardware needed)

```bash
# 1. Run a quick spawn of qemu + archlinuxarm to verify.
docker run --rm --privileged multiarch/qemu-user-static --reset -p yes

# 2. Mount the package via a chroot or a side build.
# (See docker-compose.disco.yml pattern already used in this repo.)
```

## CI integration

Add a new job to `.github/workflows/ci.yml` (the existing release workflow):

```yaml
  package-arch-arm-rpi3:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Build the cross package
        run: just package-arch-arm-rpi3
      - name: Upload artifact
        uses: actions/upload-artifact@v4
        with:
          name: mtls-hello-armv7h
          path: dist/mtls-hello-*-armv7h.pkg.tar.zst
```

This produces an artifact on every push and on every release tag, alongside the existing `.deb` and (native) `.pkg.tar.zst` files.

## Safety rules

- **No `rm -rf` / `find -delete`**: all scripts use `remove_file_safe` (anchored names + `rmdir`). Building does NOT pollute the host `/usr/`, `/var/`, or any other global path — it works inside the container.
- **No host toolchain assumption**: the Dockerfile is minimal (`pacman -Syu` only); everything else comes via `makedepends` declared in `PKGBUILD`.
- **Reproducibility**: `SOURCE_DATE_EPOCH` is set from the git commit time. Two clean builds from the same source SHA produce byte-identical payload (modulo the `builddate =` line, which macpacman renders from `SOURCE_DATE_EPOCH`).
- **Cross-arch boundary**: nothing inside the container writes to `/usr/` or `/var/` outside the staging tree. The only target paths are `/build/` (writable copy of source) and `/out/` (where the package lands).

## Diagnostic / debug commands

| To check | Run |
|----------|-----|
| Toolchain installed correctly | `docker run --rm mtls-hello-arm-rpi3-build pacman -Q arm-linux-gnueabihf-gcc` |
| Cross-compile produce correct arch | `docker run --rm mtls-hello-arm-rpi3-build file /build/bin/mtls-hello` |
| PKGBUILD parses cleanly | `docker run --rm -v $PWD:/src -v $PWD/dist:/out mtls-hello-arm-rpi3-build bash -c 'cd /build && makepkg --noarchive -s'` |
| Package contents | `tar -tvf dist/mtls-hello-*-armv7h.pkg.tar.zst \| head -20` |
| `pacman -Qi` (in a real Arch ARM chroot) | `pacman -Qi mtls-hello` (after install) |
