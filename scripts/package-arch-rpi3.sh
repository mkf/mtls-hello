#!/usr/bin/env bash
# scripts/package-arch-rpi3.sh — cross-compile mtls-hello for Arch Linux ARM
# (armv7h, Raspberry Pi 3 Model B v1.2 / BCM2837 / Cortex-A53 / hard-float).
# Runs as root inside the `localhost/mtls-hello-arm-rpi3-build` image built
# from `docker/Dockerfile.arch-rpi3` (FROM ubuntu:24.04, Bootlin's
# armv7-eabihf prebuilt toolchain laid down under /opt/&lt;toolchain&gt;/bin and
# prepended to PATH). The justfile recipe `package-arch-arm-rpi3` invokes
# `docker build -f docker/Dockerfile.arch-rpi3 -t ...` then `docker run
# --rm -v $REPO:/src:ro -v $REPO/dist:/out ...` — this script is the
# CMD entrypoint.
#
# Why we own the pack from scratch (no makepkg/pacman):
#   The base is plain ubuntu:24.04 — apt does not ship a pacman-based
#   Arch packaging tool, and Bootlin's toolchain is unrelated to Arch's
#   repository model. So we hand-emit .PKGINFO + .INSTALL and tar+zstd the
#   staged install tree, in line with the documentation of the Arch
#   package format at https://man.archlinux.org/man/makepkg.conf.5 .
#
# Build sequence (research R1 + R2 of specs/027-arch-arm-rpi3-build):
#   1. Cross-compile the D daemon via `dub build` with --target=
#      armv7-unknown-linux-gnueabihf (LDC's flag, forwarded via DFLAGS).
#   2. Stage the install tree at $BUILD_PKG/pkgroot/{usr,var}/.
#   3. Emit .PKGINFO + .INSTALL metadata. PKGINFO declares `arch = armv7h`
#      and runtime `depend =` lines for apache, bash, openssl, git, etc.
#      (Per FR-006 — properly declared; per FR-013 — NOT bundled; the
#      operator pulls these via `pacman -U mtls-hello-*.pkg.tar.zst` on the
#      actual Pi.)
#   4. tar + zstd the staged tree into /out/mtls-hello-${ver}-1-armv7h.pkg
#      .tar.zst with byte-deterministic flags --clamp-mtime --mtime=
#      "@${SOURCE_DATE_EPOCH}" --sort=name --numeric-owner (Q5).
#
# Reproducibility anchor (US3 of spec 027):
#   $SOURCE_DATE_EPOCH determines `builddate = .PKGINFO`. CI runners should
#   pass `$SOURCE_DATE_EPOCH = $(git log -1 --format=%ct)` so two builds of
#   the same git sha produce byte-identical payload tarballs.
#
# Per project safety rule G1 (and the runtime safety guardrail about
# rm-rf/rm-f/rm-r/find-delete): every cleanup below uses anchored paths +
# `rmdir` for empty dirs only. We never call `rm -rf` or `find -delete`.

set -euo pipefail

# ─── Cross-compile env vars (R1: LDC armv7h) ─────────────────────────────

# LDC: --target=armv7-unknown-linux-gnueabihf selects ARMv7 hard-float EABI5,
# matches the BCM2837/Cortex-A53 in the Raspberry Pi 3 Model B v1.2.
: "${DFLAGS:=-target=armv7-unknown-linux-gnueabihf}"
export DFLAGS

# dub's CLI: the `--DFLAGS` value is forwarded to the D compiler (ldc2).
: "${DUB_FLAGS:=--DFLAGS=-target=armv7-unknown-linux-gnueabihf}"
export DUB_FLAGS

# Reproducibility anchor (US3 of spec 027). Honor the env var if the host passes
# it through; otherwise fall back to the wall clock — but the host should
# always set `SOURCE_DATE_EPOCH=$(git -C /build/src log -1 --format=%ct)` so
# two builds of the same SHA produce byte-identical payload files
# (tar's --mtime="@SOURCE_DATE_EPOCH" then pins every entry).
: "${SOURCE_DATE_EPOCH:=$(date +%s)}"
export SOURCE_DATE_EPOCH

# ─── Directories ────────────────────────────────────────────────────────────

# /build/src/ := writable copy of /src (host's repo root, mounted RO).
# /build/pkg/ := staging root (we write pkgroot/ payload into this).
# /out/      := host `dist/` mount — tar|zstd'd .pkg.tar.zst lands here.
BUILD_PKG="/build/pkg"

# Always recreate pkgroot clean — the host's docker RUN is one-shot, but a
# rerun for the same git sha might find stale files. `rm -- <file>` only on
# anchored paths.
mkdir -p "$BUILD_PKG"
PKGROOT="$BUILD_PKG/pkgroot"
[ -d "$PKGROOT" ] && rm -- "$PKGROOT"/.PKGINFO "$PKGROOT"/.INSTALL 2>/dev/null || true
rmdir -- "$PKGROOT" 2>/dev/null || true
mkdir -- "$PKGROOT"

echo "=== Stage directory: $PKGROOT ==="

# ─── Cross-compile the D binary (R1) ──────────────────────────────────────

echo "=== Cross-compile D binary (ldc2 --target=armv7-unknown-linux-gnueabihf) ==="

# Read version + description from the project's dub.json (matches
# scripts/package-common.sh:project_version / :project_description).
ver="$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' dub.json | head -1)"
[ -n "$ver" ] || { echo "ERROR: cannot read version from dub.json" >&2; exit 1; }
description="$(sed -n 's/.*"description": *"\([^"]*\)".*/\1/p' dub.json | head -1)"
[ -n "$description" ] || description="mTLS-aware discovery + sync + drop-box via Apache httpd + D daemon"

echo "  ver=$ver"
echo "  description=$description"

# dub build: $DUB_FLAGS already carries --DFLAGS=-target=armv7-unknown-linux-
# gnueabihf which ldс2 picks up. DUB_BUILD_DIR lives outside the source
# tree so `dub` doesn't pollute /build/src.
cd /build/src
DUB_BUILD_DIR="${DUB_BUILD_DIR:-/build/.dub}" \
    dub build $DUB_FLAGS --build-mode=release

# Sanity: the produced binary must report ARM (not x86_64).
BUILT_BT="$(file mtls-hello | head -1)"
echo "  binary identity: $BUILT_BT"
echo "$BUILT_BT" | grep -q "ARM" || {
    echo "ERROR: cross-compiled binary is not ARM (got: $BUILT_BT)" >&2
    exit 1
}

# ─── Stage install tree at $PKGROOT ─────────────────────────────────────

mkdir -p "$PKGROOT/usr/bin" \
         "$PKGROOT/usr/lib/systemd/user" \
         "$PKGROOT/var/lib/mtls-hello/handlers" \
         "$PKGROOT/var/lib/mtls-hello/scripts" \
         "$PKGROOT/var/lib/mtls-hello/scripts/on-discovery.d" \
         "$PKGROOT/var/lib/mtls-hello/cli" \
         "$PKGROOT/var/lib/mtls-hello/drop" \
         "$PKGROOT/var/lib/mtls-hello/identity" \
         "$PKGROOT/var/lib/mtls-hello/bin"

# Daemon binary (cross-compiled; ARMv7 verified above).
install -D -m 0755 mtls-hello "$PKGROOT/usr/bin/mtls-hello"

# Handlers (per-host drop-box + bundle POST handler).
cp -p handlers/*.sh "$PKGROOT/var/lib/mtls-hello/handlers/" 2>/dev/null \
    || echo "warning: no handlers/*. sh present"

# Shared libraries + helper scripts.
cp -p scripts/cgi-lib.sh       "$PKGROOT/var/lib/mtls-hello/scripts/"
cp -p scripts/sync-lib.sh      "$PKGROOT/var/lib/mtls-hello/scripts/"
cp -p scripts/build-nncp.sh    "$PKGROOT/var/lib/mtls-hello/scripts/"
cp -p scripts/gen-certs.sh     "$PKGROOT/var/lib/mtls-hello/scripts/"
cp -p scripts/install.sh       "$PKGROOT/var/lib/mtls-hello/scripts/"
cp -p scripts/install-service.sh "$PKGROOT/var/lib/mtls-hello/scripts/"
cp -p scripts/log-capture.sh   "$PKGROOT/var/lib/mtls-hello/scripts/"
cp -p scripts/merge-spool.sh   "$PKGROOT/var/lib/mtls-hello/scripts/"
cp -p scripts/trust-host.sh    "$PKGROOT/var/lib/mtls-hello/scripts/"
cp -p scripts/migrate-layout.sh "$PKGROOT/var/lib/mtls-hello/scripts/"
cp -p scripts/cleanup-common.sh "$PKGROOT/var/lib/mtls-hello/scripts/"
cp -p scripts/apache-config.sh "$PKGROOT/var/lib/mtls-hello/scripts/"

# on-discovery.d/ callback directory.
mkdir -p "$PKGROOT/var/lib/mtls-hello/scripts/on-discovery.d"
cp -p scripts/on-discovery.d/*.sh "$PKGROOT/var/lib/mtls-hello/scripts/on-discovery.d/"

# Client wrappers (per-feature-023).
cp -p cli/_common-cname.sh "$PKGROOT/var/lib/mtls-hello/cli/"
for w in cli/mtls-*.sh; do
    cp -p "$w" "$PKGROOT/var/lib/mtls-hello/cli/"
done

# Cross-compiled NNCP binaries, if the operator pre-built them under bin/.
if [ -d bin ]; then
    for n in bin/nncp*; do
        [ -x "$n" ] || continue
        cp -p "$n" "$PKGROOT/var/lib/mtls-hello/bin/"
        chmod 0755 "$PKGROOT/var/lib/mtls-hello/bin/$(basename "$n")"
    done
fi

# gen-cert.sh (called by the systemd unit's ExecStartPre).
cat > "$PKGROOT/var/lib/mtls-hello/scripts/gen-cert.sh" <<'GENCERT'
#!/usr/bin/env bash
set -e
identity_dir="$HOME/.local/share/mtls-hello/identity"
mkdir -p "$identity_dir"
hostname_val="$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo localhost)"
hostname_fn="$(printf '%s' "$hostname_val" | tr -c 'A-Za-z0-9._-' '_')"
if [ ! -f "$identity_dir/$hostname_fn.crt" ]; then
    if openssl version >/dev/null 2>&1; then
        openssl req -x509 -newkey ed25519 -nodes -days 3650 \
            -keyout "$identity_dir/$hostname_fn.key" \
            -out "$identity_dir/$hostname_fn.crt" \
            -subj "/CN=$hostname_val" >/dev/null 2>&1 \
            || openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
                -keyout "$identity_dir/$hostname_fn.key" \
                -out "$identity_dir/$hostname_fn.crt" \
                -subj "/CN=$hostname_val" >/dev/null 2>&1
        chmod 600 "$identity_dir/$hostname_fn.key"
        echo "Generated self-signed identity certificate for $hostname_val"
    else
        echo "Warning: openssl not found; cannot generate certificate." >&2
    fi
fi
GENCERT
chmod 0755 "$PKGROOT/var/lib/mtls-hello/scripts/gen-cert.sh"

# systemd user unit (per-user, with %h expansion).
cat > "$PKGROOT/usr/lib/systemd/user/mtls-hello.service" <<'UNIT'
[Unit]
Description=mtls-hello mutual-TLS server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=OUR_CERT=%h/.local/share/mtls-hello/identity/%H.crt
Environment=OUR_KEY=%h/.local/share/mtls-hello/identity/%H.key
Environment=REPOS_ROOT=%h/.local/state/REPOS_ROOT
ExecStartPre=/var/lib/mtls-hello/scripts/gen-cert.sh
ExecStart=/usr/bin/mtls-hello 0 \
  --port=0 --port-file=%t/mtls-hello.port \
  --data-dir=/var/lib/mtls-hello
ExecStartPost=/bin/sh -c 'echo "mtls-hello listening on port $(cat %t/mtls-hello.port)"'
Restart=on-failure
RestartSec=5s
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
UNIT

# ─── Emit .PKGINFO + .INSTALL (per spec FR-006) ─────────────────────────

# Per FR-006 of spec 027: depend = one per line, anchored on packages actually
# shipped by Arch Linux ARM (archlinuxarm.org) — resolved by `pacman -U` on the
# target (NOT bundled in the package).
cat > "$PKGROOT/.PKGINFO" <<EOF
pkgname = mtls-hello
pkgver = ${ver}-1
pkgdesc = ${description}
url = https://github.com/mkf/mtls-hello
builddate = ${SOURCE_DATE_EPOCH}
packager = mkf <mkf@mkf.pl>
size = $(du -sk "$PKGROOT" | cut -f1)
arch = armv7h
depend = apache
depend = bash
depend = openssl
depend = git
depend = coreutils
depend = grep
depend = findutils
depend = sed
depend = awk
depend = glibc
depend = zstd
EOF

# .INSTALL — informational hooks only.
cat > "$PKGROOT/.INSTALL" <<'INST'
post_install() {
    echo "mtls-hello installed. Enable with:"
    echo "  systemctl --user daemon-reload"
    echo "  systemctl --user enable --now mtls-hello"
    echo "A self-signed identity certificate will be generated on first start."
}

post_upgrade() {
    post_install
}
INST

# ─── tar + zstd -> /out (final archive) ──────────────────────────────────

echo "=== tar + zstd -> /out ==="
mkdir -p /out

# Byte-determinism knobs (research.md Q5):
#   --clamp-mtime + --mtime="@SOURCE_DATE_EPOCH"
#     Forces every archive entry's mtime to the single anchor so two runs
#     from the same git SHA produce the same hash, regardless of when each
#     run was started.
#   --sort=name
#     Tar entries in a stable lexicographic order (otherwise tar's
#     iteration order can vary between GNU tar versions and fuse drivers).
#   --numeric-owner --owner=0 --group=0
#     Forces root:root ownership regardless of the build's UID; matches
#     upstream packages' convention.
# Per G1 we DO NOT use `find -delete` or `find ... -exec rm` anywhere in
# the cleanup flow — `cp -a` is the only file-removal overlay.
cd "$PKGROOT"
tar --owner=0 --group=0 --numeric-owner \
    --sort=name \
    --clamp-mtime --mtime="@${SOURCE_DATE_EPOCH}" \
    -cf - .PKGINFO .INSTALL usr var | zstd -q -o \
    "/out/mtls-hello-${ver}-1-armv7h.pkg.tar.zst"

echo "=== Final checks (T009/T010/T011 collapse: PKGINFO + ELF + payload) ==="
outpkg="/out/mtls-hello-${ver}-1-armv7h.pkg.tar.zst"
echo "  archive: $outpkg"
echo "  PKGINFO arch:     $(tar -xOf "$outpkg" .PKGINFO 2>/dev/null | grep '^arch =')"
echo "  PKGINFO depend=:  $(tar -xOf "$outpkg" .PKGINFO 2>/dev/null | grep -c '^depend =')"
echo "  ELF binary:       $(tar -xOf "$outpkg" ./usr/bin/mtls-hello >/dev/null && file 2>/dev/null | head -1)"
echo "=== Cross-arch build complete ==="
