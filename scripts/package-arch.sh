#!/usr/bin/env bash
# Build an Arch Linux .pkg.tar.zst package for mtls-hello.
# Runs on Arch with ldc, dub, openssl, zstd installed.
# No Guix — builds natively with the host toolchain.
set -euo pipefail

cd "$(dirname "$0")/.."   # repo root

# shellcheck source=package-common.sh
. scripts/package-common.sh

check_build_deps
build_binary

version="$(project_version)"
description="$(project_description)"
pkgroot="$(mktemp -d)"
trap 'rm -rf "$pkgroot"' EXIT

stage_install_tree "$pkgroot"

# Arch .PKGINFO metadata.
cat > "$pkgroot/.PKGINFO" <<EOF
pkgname = mtls-hello
pkgver = ${version}-1
arch = x86_64
pkgdesc = ${description}
url = https://github.com/mikf/mtls-hello
builddate = $(date +%s)
packager = mika <m@mikf.pl>
size = $(du -sk "$pkgroot" | cut -f1)
depend = openssl
depend = ldc
EOF

# .INSTALL: generate self-signed cert if missing.
# .INSTALL: informational only. Cert generation happens on first
# service start via the systemd unit's ExecStartPre (runs as the user).
cat > "$pkgroot/.INSTALL" <<'INSTALL'
post_install() {
    echo "mtls-hello installed. Enable with:"
    echo "  systemctl --user daemon-reload"
    echo "  systemctl --user enable --now mtls-hello"
    echo "A self-signed certificate will be generated on first start."
}

post_upgrade() {
    post_install
}
INSTALL

# Build the .pkg.tar.zst (direct tar+zstd, no makepkg needed).
# Pacman requires .PKGINFO at the archive root with no ./ prefix, so we
# cd into the pkgroot and tar from there.
outdir="${PKG_OUTPUT_DIR:-dist}"
mkdir -p "$outdir"
abs_outdir="$(cd "$outdir" 2>/dev/null && pwd)"
[ -z "$abs_outdir" ] && abs_outdir="$outdir"
pkg="$abs_outdir/mtls-hello-${version}-1-x86_64.pkg.tar.zst"
rm -f "$pkg"
# .PKGINFO and .INSTALL must be first in the archive.
cd "$pkgroot"
tar --owner=0 --group=0 -cf - .PKGINFO .INSTALL var usr | zstd -q -o "$pkg"
echo "Built $pkg"
