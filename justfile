# mtls-hello — mutual-TLS D HTTP server (vibe.d)
#
# Everything runs inside `guix shell -f guix.scm` so the build links against a
# real OpenSSL 3.x instead of the host's LibreSSL. LDC is used because Guix's
# `dmd` is GNU Shepherd, not the D compiler.

set shell := ["bash", "-c"]
set positional-arguments := false

# LDC in the Guix shell needs a `cc` driver and bfd linker because:
#   - gcc-toolchain has no `cc` symlink
#   - LDC defaults to `-fuse-ld=gold` but Guix binutils has no `ld.gold`
#   - the openssl bindings pre-generate step needs $DC set
#   - dub 1.23 in Guix needs --skip-registry=standard to avoid registry TLS failures
_build_vars := "mkdir -p .guix-bin && ln -sf \"$(command -v gcc)\" .guix-bin/cc && PATH=\"$PWD/.guix-bin:$PATH\" DFLAGS=\"--linker=bfd\" DC=\"ldc2 --linker=bfd\" SKIP_REGISTRY=\"--skip-registry=standard\""
_run_env := "LD_LIBRARY_PATH=\"$GUIX_ENVIRONMENT/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}\""

# enter the guix dev shell
default:
    guix shell -f guix.scm

# build the server binary
build:
    guix shell -f guix.scm -- sh -c 'bash scripts/version.sh && {{ _build_vars }} dub build --compiler=ldc2 $SKIP_REGISTRY'

# run the server: just run -- [port] [cert] [key]
run *args:
    guix shell -f guix.scm -- sh -c '{{ _build_vars }} {{ _run_env }} exec dub run --compiler=ldc2 $SKIP_REGISTRY -- {{ args }}'

# run the BATS end-to-end tests (spins up its own server)
test:
    guix shell -f guix.scm -- sh -c '{{ _build_vars }} {{ _run_env }} exec bats tests/'

# install the binary and default handlers to ~/.local
install:
    guix shell -f guix.scm -- bash scripts/install.sh

# generate a systemd user service unit for the current user
install-service:
    guix shell -f guix.scm -- bash scripts/install-service.sh

# build a self-extracting installer script for non-Guix targets
self-extract:
    guix shell -f guix.scm -- sh -c 'bash scripts/version.sh && {{ _build_vars }} dub build --compiler=ldc2 $SKIP_REGISTRY && bash scripts/self-extract-build.sh'

# build a Debian .deb package (run on Debian/Ubuntu with ldc, dub, libssl-dev)
package-debian:
    bash scripts/package-debian.sh

# build an Arch .pkg.tar.zst package (run on Arch with ldc, dub, openssl)
package-arch:
    bash scripts/package-arch.sh

# detect distro and build the native package (Debian or Arch)
package:
    bash scripts/package.sh

# build both packages via Docker (works on any host with Docker)
package-docker:
    bash docker/docker-build.sh

# clean build artifacts
clean:
    guix shell -f guix.scm -- sh -c '{{ _build_vars }} dub clean'
