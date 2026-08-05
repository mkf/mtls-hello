#!/usr/bin/env bash
# Build both a Debian .deb and an Arch .pkg.tar.zst via Docker containers.
# Works on any host with Docker — no Guix, no host D compiler required.
# Source is mounted read-only; packages are written to dist/.
set -euo pipefail

cd "$(dirname "$0")/.."   # repo root

# Check Docker is available.
if ! command -v docker >/dev/null 2>&1; then
    echo "Error: docker not found on PATH. Install Docker and ensure the daemon is running." >&2
    exit 1
fi
if ! docker info >/dev/null 2>&1; then
    echo "Error: Docker daemon is not running. Start it and try again." >&2
    exit 1
fi

mkdir -p dist

echo "=== Building Debian package ==="
docker build -t mtls-hello-build-debian -f docker/Dockerfile.debian .
docker run --rm \
    -v "$PWD:/src:ro" \
    -v "$PWD/dist:/out" \
    -v mtls-dub-cache-deb:/root/.dub \
    mtls-hello-build-debian

echo "=== Building Arch package ==="
docker build -t mtls-hello-build-arch -f docker/Dockerfile.arch .
docker run --rm \
    -v "$PWD:/src:ro" \
    -v "$PWD/dist:/out" \
    -v mtls-dub-cache-arch:/root/.dub \
    mtls-hello-build-arch

echo "=== Done ==="
ls -lh dist/mtls-hello_*.deb dist/mtls-hello-*.pkg.tar.zst 2>/dev/null
