#!/usr/bin/env bash
# Distro-detecting entry point: sniffs /etc/os-release and dispatches to the
# right native packaging script. On unsupported distros, exits with an error
# suggesting `just package-docker`.
#
#   bash scripts/package.sh           — build the native package for this distro
#   bash scripts/package.sh --detect  — print detected distro family and exit
set -euo pipefail

cd "$(dirname "$0")/.."

detect_distro() {
    local id="" id_like=""
    local os_release="${OS_RELEASE_FILE:-/etc/os-release}"
    if [ -f "$os_release" ]; then
        # shellcheck disable=SC1090
        . "$os_release"
        id="${ID:-}"
        id_like="${ID_LIKE:-}"
    fi

    if echo "$id $id_like" | grep -qw debian; then
        echo debian
        return 0
    fi
    if [ "$id" = "arch" ] || echo "$id_like" | grep -qw arch; then
        echo arch
        return 0
    fi
    return 1
}

if [ "${1:-}" = "--detect" ]; then
    detect_distro
    exit $?
fi

distro=""
if ! distro="$(detect_distro)"; then
    id="${ID:-unknown}"
    cat >&2 <<EOF
Error: unsupported distribution '$id'.
Supported: debian (incl. Ubuntu), arch.
Use 'just package-docker' to build both packages via Docker on any host.
EOF
    exit 1
fi

echo "Detected distro: $distro"
case "$distro" in
    debian) exec bash scripts/package-debian.sh ;;
    arch)   exec bash scripts/package-arch.sh ;;
esac
