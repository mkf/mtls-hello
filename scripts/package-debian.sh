#!/usr/bin/env bash
# Build a Debian .deb package for mtls-hello.
# Runs on Debian/Ubuntu with ldc, dub, libssl-dev, dpkg-deb installed.
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
trap 'cleanup_pkgroot "$pkgroot"' EXIT

stage_install_tree "$pkgroot"

# Debian control metadata.
mkdir -p "$pkgroot/DEBIAN"
cat > "$pkgroot/DEBIAN/control" <<EOF
Package: mtls-hello
Version: ${version}
Architecture: amd64
Maintainer: mika <m@mikf.pl>
Depends: libc6, libssl3, openssl, libphobos2-ldc-shared100
Section: net
Priority: optional
Description: ${description}
 mtls-hello is a mutual-TLS HTTP server with LAN multicast discovery
 and Git repository synchronization.
EOF

# Post-install: informational only. Cert generation happens on first
# service start via the systemd unit's ExecStartPre (runs as the user).
cat > "$pkgroot/DEBIAN/postinst" <<'POSTINST'
#!/usr/bin/env bash
set -e
echo "mtls-hello installed. Enable with:"
echo "  systemctl --user daemon-reload"
echo "  systemctl --user enable --now mtls-hello"
echo "A self-signed certificate will be generated on first start."
POSTINST
chmod 755 "$pkgroot/DEBIAN/postinst"

# Build the .deb.
outdir="${PKG_OUTPUT_DIR:-dist}"
mkdir -p "$outdir"
deb="$outdir/mtls-hello_${version}_amd64.deb"
remove_file_safe "$deb"
dpkg-deb --build "$pkgroot" "$deb"
echo "Built $deb"
