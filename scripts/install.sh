#!/usr/bin/env bash
set -euo pipefail

binary="./mtls-hello"
if [ ! -f "$binary" ]; then
    echo "Error: mtls-hello binary not found. Run 'just build' first." >&2
    exit 1
fi

mkdir -p "$HOME/.local/bin"
mkdir -p "$HOME/.local/share/mtls-hello"
mkdir -p "$HOME/.local/share/mtls-hello/scripts"

install -D -m 755 "$binary" "$HOME/.local/bin/mtls-hello"

if [ -d "$HOME/.local/share/mtls-hello/handlers" ]; then
    rm -rf "$HOME/.local/share/mtls-hello/handlers"
fi

cp -r handlers "$HOME/.local/share/mtls-hello/handlers"
cp -p scripts/on-discover.sh "$HOME/.local/share/mtls-hello/scripts/on-discover.sh"
cp -p scripts/trust-host.sh "$HOME/.local/share/mtls-hello/scripts/trust-host.sh"
# .new files are always overwritten with latest defaults.
# User-created files (without .new) are never touched.
cp -p scripts/pre-push.sh.new "$HOME/.local/share/mtls-hello/scripts/pre-push.sh.new"
# Generate self-signed server certificate on first install if missing.
mkdir -p "$HOME/.local/share/mtls-hello/certs/certs" "$HOME/.local/share/mtls-hello/certs/private"
if [ ! -f "$HOME/.local/share/mtls-hello/certs/certs/server.crt" ]; then
    if ! openssl version >/dev/null 2>&1; then
        echo "Warning: openssl not found; cannot generate self-signed server certificate." >&2
        echo "Install openssl or provide certificates manually." >&2
    else
        openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
            -keyout "$HOME/.local/share/mtls-hello/certs/private/server.key" \
            -out "$HOME/.local/share/mtls-hello/certs/certs/server.crt" \
            -subj "/CN=$(hostname)" >/dev/null 2>&1
        chmod 600 "$HOME/.local/share/mtls-hello/certs/private/server.key"
        echo "Generated self-signed server certificate for $(hostname)"
    fi
fi

# Vendor Guix-provided shared libraries so the binary runs without guix shell.
# GUIX_ENVIRONMENT may be unset when running outside the guix shell.
mkdir -p "$HOME/.local/lib/mtls-hello"
for lib in libssl.so.3 libcrypto.so.3 libz.so.1 libphobos2-ldc-shared.so.97 libdruntime-ldc-shared.so.97; do
  if [ -n "${GUIX_ENVIRONMENT:-}" ]; then
    src=$(find "$GUIX_ENVIRONMENT" /gnu/store -name "$lib" -not -path "*.drv*" -type f,l 2>/dev/null | head -1)
  else
    src=$(find /gnu/store -name "$lib" -not -path "*.drv*" -type f,l 2>/dev/null | head -1)
  fi
  if [ -n "$src" ]; then
    rm -f "$HOME/.local/lib/mtls-hello/$lib"
    cp "$src" "$HOME/.local/lib/mtls-hello/$lib"
  fi
done

echo "Installed mtls-hello to $HOME/.local/bin/mtls-hello"
echo "Installed handlers to $HOME/.local/share/mtls-hello/handlers/"
echo "Installed discovery callback to $HOME/.local/share/mtls-hello/scripts/on-discover.sh"
echo "Installed hook templates (*.new) to $HOME/.local/share/mtls-hello/scripts/"
echo "Installed certificates to $HOME/.local/share/mtls-hello/certs/"
echo "Vendored runtime libs to $HOME/.local/lib/mtls-hello/"
echo
echo "To activate a hook: cp <name>.new <name> && chmod +x <name>"
echo "Re-running install overwrites .new files but preserves your custom files."
echo
echo "If ~/.local/bin is not on your PATH, add:"
echo '  export PATH="$HOME/.local/bin:$PATH"'
echo
echo "To enable discovery-triggered sync, set:"
echo '  export CALLBACK_SCRIPT="$HOME/.local/share/mtls-hello/scripts/on-discover.sh"'
echo "(Required — the server has no default path for CALLBACK_SCRIPT.)"
