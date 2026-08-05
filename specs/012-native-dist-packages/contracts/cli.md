# CLI Contract: Package Build Commands

## Synopsis

```
just package-debian        # build .deb on a Debian/Ubuntu host
just package-arch          # build .pkg.tar.zst on an Arch host
just package               # detect distro, dispatch to the right native script
just package-docker        # build both packages via Docker (any host)
```

## `just package-debian`

Builds a Debian `.deb` package from source on the current host. Assumes the host is Debian/Ubuntu with `ldc`, `dub`, `libssl-dev`, `dpkg-deb` installed.

**Preconditions**: `ldc` and `dub` on PATH; `dpkg-deb` available; OpenSSL dev headers installed.

**Postconditions**: `dist/mtls-hello_<version>_amd64.deb` exists.

**Exit codes**: `0` success; `1` build or packaging failure.

## `just package-arch`

Builds an Arch `.pkg.tar.zst` package from source on the current host. Assumes the host is Arch with `ldc`, `dub`, `openssl`, `makepkg`/`pacman` installed.

**Preconditions**: `ldc` and `dub` on PATH; `makepkg` available; OpenSSL dev headers installed.

**Postconditions**: `dist/mtls-hello-<version>-1-x86_64.pkg.tar.zst` exists.

**Exit codes**: `0` success; `1` build or packaging failure.

## `just package`

Detects the host distribution via `/etc/os-release` and dispatches to `package-debian.sh` or `package-arch.sh`. On an unsupported distro, exits non-zero with a message naming the supported distros.

**Preconditions**: same as the dispatched native script; OR use `just package-docker` instead if the host is unsupported.

**Exit codes**: `0` success; `1` unsupported distro or build failure.

**Stderr on unsupported**: `Error: unsupported distribution '<ID>'. Supported: debian, arch. Use 'just package-docker' to build both via Docker.`

## `just package-docker`

Builds **both** a Debian `.deb` and an Arch `.pkg.tar.zst` using Docker containers. Works on any host with Docker, regardless of the host's own distro. Each container installs its own toolchain from scratch; the source is mounted read-only.

**Preconditions**: `docker` on PATH; Docker daemon running.

**Postconditions**: `dist/mtls-hello_<version>_amd64.deb` and `dist/mtls-hello-<version>-1-x86_64.pkg.tar.zst` both exist.

**Exit codes**: `0` both packages built; `1` Docker unavailable or a build failed.

**Stdout**: Progress — which container is building, where the package was written.

**Stderr**: Warnings and errors.
