#!/usr/bin/env bash
set -euo pipefail

# Build a self-extracting installer script. Called from the justfile.
# Outputs: mtls-hello-installer-<short-hash>-<YYYYMMDD>[-dirty].sh

binary="./mtls-hello"
if [ ! -f "$binary" ]; then
    echo "Error: mtls-hello binary not found. Run 'just build' first." >&2
    exit 1
fi

stage=$(mktemp -d)
trap 'rm -rf "$stage" "$stage.tar.gz" "$stage.tar.gz.b64" 2>/dev/null || true' EXIT

mkdir -p "$stage/bin" "$stage/lib/mtls-hello" "$stage/share/mtls-hello/handlers" "$stage/share/mtls-hello/scripts"

install -D -m 755 "$binary" "$stage/bin/mtls-hello"

# Patch the binary so it runs on non-Guix targets: replace the Guix-specific
# dynamic linker with the standard Linux one, and set an rpath relative to
# the binary so it finds the vendored libraries without LD_LIBRARY_PATH.
if command -v patchelf >/dev/null 2>&1; then
    patchelf --set-interpreter /lib64/ld-linux-x86-64.so.2 "$stage/bin/mtls-hello"
    patchelf --set-rpath '$ORIGIN/../lib/mtls-hello' "$stage/bin/mtls-hello"
else
    echo "Warning: patchelf not found; the binary will only run inside Guix." >&2
fi

# Vendor Guix-provided shared libraries so the binary runs without guix shell.
for lib in libssl.so.3 libcrypto.so.3 libz.so.1 libphobos2-ldc-shared.so.97 libdruntime-ldc-shared.so.97; do
    src=$(find "${GUIX_ENVIRONMENT:-}" /gnu/store -name "$lib" -not -path "*.drv*" -type f,l 2>/dev/null | head -1)
    if [ -n "$src" ]; then
        rm -f "$stage/lib/mtls-hello/$lib"
        cp "$src" "$stage/lib/mtls-hello/$lib"
    else
        echo "Warning: could not find library $lib" >&2
    fi
done

# Handlers and hook templates.
cp -r handlers "$stage/share/mtls-hello/"
cp -p scripts/on-discover.sh "$stage/share/mtls-hello/scripts/"
cp -p scripts/pre-push.sh.new "$stage/share/mtls-hello/scripts/"

# Pack and encode the payload.
tar czf "$stage.tar.gz" -C "$stage" .
base64 "$stage.tar.gz" > "$stage.tar.gz.b64"

# Git-derived filename metadata.
hash=$(git rev-parse --short HEAD)
date=$(date +%Y%m%d)
dirty=""
if [ -n "$(git status --porcelain)" ]; then
    dirty="-dirty"
fi
out="mtls-hello-installer-${hash}-${date}${dirty}.sh"

# Assemble: template + base64 payload after the __PAYLOAD__ marker.
{
    cat scripts/self-extract.in
    cat "$stage.tar.gz.b64"
} > "$out"
chmod +x "$out"

echo "$out"
