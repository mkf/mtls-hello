# mtls-hello — mTLS discovery daemon and Apache-backed HTTPS server
#
# The D binary performs LAN multicast discovery and peer certificate capture.
# Apache httpd serves the HTTPS endpoints via CGI handlers.
# Everything runs inside a plain Nix shell (nix-shell, no flakes) so the build
# links against a real OpenSSL 3.x instead of the host's LibreSSL.

set shell := ["bash", "-c"]
set positional-arguments := true

# Dub is told to use the local package cache once it is populated. Do not keep
# rebuilding the D dependencies; the Nix shell provides the toolchain only.
DUB_FLAGS := "--compiler=ldc2 --skip-registry=standard"

# enter the nix dev shell
default:
    nix-shell

# build the server binary
build:
    nix-shell --run 'python3 scripts/version.py && dub build {{ DUB_FLAGS }}'

# run the discovery daemon: just run -- [advertised-port] [options]
run *args:
    nix-shell --run 'exec dub run {{ DUB_FLAGS }} -- {{args}}'

# run the D unit tests
# filter: just test-d -- --filter "capture"
test-d *args:
    nix-shell --run 'dub build --config=unittest --build=unittest {{ DUB_FLAGS }} {{ args }}'
    nix-shell --run 'exec ./mtls-hello-unittest'

# run the BATS end-to-end tests (spins up its own server)
# filter: just test --filter "bare-repo sync"
test *args:
    nix-shell --run 'LD_LIBRARY_PATH="" bats tests/ {{args}}'

# run the Robot Framework end-to-end tests (new, will replace BATS over time)
# filter: just robot -- -i smoke
robot *args:
    nix-shell --run 'robot -d robot-output robot/ {{args}}'

# run only the drop-box Robot tests (feature 023)
robot-dropbox *args:
    nix-shell --run 'robot -d robot-output robot/dropbox.robot {{args}}'

# run tests in Docker (matches CI environment, no Nix needed)
# filter: just test-docker --filter "bare-repo sync"
test-docker *args:
    docker build -t mtls-hello-build-debian -f docker/Dockerfile.debian . \
        && docker build -t mtls-hello-test -f docker/Dockerfile.test . \
        && docker run --rm -v "$PWD:/src:ro" -v mtls-dub-test:/root/.dub \
           mtls-hello-test bash -c 'cp -a /src /build && cd /build && rm -rf .dub && DC=ldc2 dub build --compiler=ldc2 && bats tests/ "$@"' _ "$@"

# install the binary and default handlers to ~/.local
install:
    nix-shell --run 'LD_LIBRARY_PATH="" bash scripts/install.sh'

# generate a systemd user service unit for the current user
install-service:
    nix-shell --run 'LD_LIBRARY_PATH="" bash scripts/install-service.sh'

# build a self-extracting installer script for non-Nix targets
self-extract:
    nix-shell --run 'sh scripts/version.sh && dub build {{ DUB_FLAGS }} && bash scripts/self-extract-build.sh'

# build a Debian .deb package (run on Debian/Ubuntu with ldc, dub, libssl-dev)
package-debian:
    bash scripts/package-debian.sh

# build an Arch .pkg.tar.zst package (run on Arch with ldc, dub, openssl)
package-arch:
    bash scripts/package-arch.sh

# build an Arch Linux ARM armv7h .pkg.tar.zst package (cross-compiled for
# Raspberry Pi 3 Model B v1.2). Runs in a Docker container invoked from
# docker/Dockerfile.arch-rpi3, which uses makepkg -s to auto-install
# makedepends declared in docker/pkgbuilds/mtls-hello.PKGBUILD.
package-arch-arm-rpi3:
    docker build -f docker/Dockerfile.arch-rpi3 -t localhost/mtls-hello-arm-rpi3-build .
    mkdir -p dist
    docker run --rm \
        -v "$(CURDIR):/src:ro" \
        -v "$(CURDIR)/dist:/out" \
        localhost/mtls-hello-arm-rpi3-build

# detect distro and build the native package (Debian or Arch)
package:
    bash scripts/package.sh

# build both packages via Docker (works on any host with Docker)
package-docker:
    bash docker/docker-build.sh

# clean build artifacts
clean:
    nix-shell --run 'dub clean'
