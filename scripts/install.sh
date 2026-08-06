#!/usr/bin/env bash
set -euo pipefail

binary="./mtls-hello"
if [ ! -f "$binary" ]; then
    echo "Error: mtls-hello binary not found. Run 'just build' first." >&2
    exit 1
fi

# Safe-deletion helpers (no rm -rf / rm -f anywhere).
# shellcheck source=scripts/cleanup-common.sh
. "$(dirname "$0")/cleanup-common.sh"

mkdir -p "$HOME/.local/bin"
mkdir -p "$HOME/.local/share/mtls-hello"
mkdir -p "$HOME/.local/share/mtls-hello/scripts"
mkdir -p "$HOME/.local/share/mtls-hello/drop"
mkdir -p "$HOME/.local/share/mtls-hello/cli"

install -D -m 755 "$binary" "$HOME/.local/bin/mtls-hello"

HANDLERS_DST="$HOME/.local/share/mtls-hello/handlers"
if [ -d "$HANDLERS_DST" ]; then
    # Remove the handler scripts we ship, then drop the dir if it is now empty.
    for h in hello.get.sh head.get.sh spool.get.sh bundle.post.sh cert-echo.get.sh drop-proxy.sh; do
        remove_file_safe "$HANDLERS_DST/$h"
    done
    rmdir -- "$HANDLERS_DST" || echo "warning: $HANDLERS_DST not empty after removing known handlers" >&2
fi
mkdir -p "$HANDLERS_DST"
cp -p handlers/hello.get.sh handlers/head.get.sh handlers/spool.get.sh \
    handlers/bundle.post.sh handlers/cert-echo.get.sh handlers/drop-proxy.sh "$HANDLERS_DST/"
# Install client wrappers.
for w in cli/_common-cname.sh cli/mtls-*.sh; do
    cp -p "$w" "$HOME/.local/share/mtls-hello/cli/"
done
# Remove the legacy single-callback script if present (anchored filename,
# `rm --`, never `rm -f` / `rm -rf`, per project's safety rule G1).
[ -e "$HOME/.local/share/mtls-hello/scripts/on-discover.sh" ] && \
    rm -- "$HOME/.local/share/mtls-hello/scripts/on-discover.sh"

# Drop the new feature-025 directory tree wholesale. Each numbered script
# inside is sourced/re-sourced from $_run-parts.sh at discovery time.
install -d -m 0755 "$HOME/.local/share/mtls-hello/scripts/on-discovery.d"
for f in scripts/on-discovery.d/*.sh; do
    [ -e "$f" ] || continue
    cp -p "$f" "$HOME/.local/share/mtls-hello/scripts/on-discovery.d/"
    chmod 0755 "$HOME/.local/share/mtls-hello/scripts/on-discovery.d/$(basename -- "$f")" || true
done
cp -p scripts/sync-common.sh "$HOME/.local/share/mtls-hello/scripts/sync-common.sh"
cp -p scripts/trust-host.sh "$HOME/.local/share/mtls-hello/scripts/trust-host.sh"
cp -p scripts/merge-spool.sh "$HOME/.local/share/mtls-hello/scripts/merge-spool.sh"
cp -p scripts/cgi-trust.sh "$HOME/.local/share/mtls-hello/scripts/cgi-trust.sh"
cp -p scripts/log-capture.sh "$HOME/.local/share/mtls-hello/scripts/log-capture.sh"
cp -p scripts/cgi-common.sh "$HOME/.local/share/mtls-hello/scripts/cgi-common.sh"
cp -p scripts/apache-config.sh "$HOME/.local/share/mtls-hello/scripts/apache-config.sh"
cp -p scripts/migrate-layout.sh "$HOME/.local/share/mtls-hello/scripts/migrate-layout.sh"
# .new files are always overwritten with latest defaults.
# User-created files (without .new) are never touched.
cp -p scripts/pre-push.sh.new "$HOME/.local/share/mtls-hello/scripts/pre-push.sh.new"
# Generate identity material on first install if missing. We use
# scripts/gen-certs.sh which is feature-025-aware: writes Ed25519+X25519 keys
# directly into BOTH the mTLS cert at identity/<cn>.{crt,key} AND the NNCP-format
# <data-dir>/nncp.hjson self: block. Idempotent.
HOST="$(hostname)"
# Sanitize the hostname for the filename (keep [A-Za-z0-9._-], else '_').
HOST_FN="$(printf '%s' "$HOST" | tr -c 'A-Za-z0-9._-' '_')"
mkdir -p "$HOME/.local/share/mtls-hello/identity"
if [ ! -f "$HOME/.local/share/mtls-hello/identity/$HOST_FN.crt" ]; then
    if ! command -v openssl >/dev/null 2>&1; then
        echo "Warning: openssl not found; cannot generate self-signed identity certificate." >&2
        echo "Install openssl or provide certificates manually." >&2
    else
        if bash "$(dirname "$0")/gen-certs.sh" --cn "$HOST" -d "$HOME/.local/share/mtls-hello" \
            >"$HOME/.local/share/mtls-hello/install-gencerts.log" 2>&1; then
            echo "Generated Ed25519+X25519 identity for $HOST"
        else
            echo "gen-certs.sh failed; check $HOME/.local/share/mtls-hello/install-gencerts.log" >&2
        fi
    fi
fi

# Build the NNCP single binary from /tmp/nncp-8.13.0 source and symlink the
# subcommand names the project actually uses (nncp-toss, nncp-call, nncp-stat,
# nncp-cfgnew, ...) into <data-dir>/bin/. Idempotent: re-running only refreshes
# the symlinks if the binary is already present.
if [ -d /tmp/nncp-8.13.0 ] && [ -f /tmp/nncp-8.13.0/src/cmd/nncp/main.go ]; then
    if bash "$(dirname "$0")/build-nncp.sh" --src /tmp/nncp-8.13.0 --dir "$HOME/.local/share/mtls-hello/bin" \
        >"$HOME/.local/share/mtls-hello/install-buildnncp.log" 2>&1; then
        echo "Built NNCP binary at $HOME/.local/share/mtls-hello/bin/nncp"
    else
        echo "build-nncp.sh failed; check $HOME/.local/share/mtls-hello/install-buildnncp.log" >&2
    fi
else
    echo "Note: /tmp/nncp-8.13.0 not present; skipping NNCP build." >&2
    echo "      /nncp/receive/ will return 501 until the binary is installed." >&2
fi

# Migrate a legacy nested certs/ layout to the flat layout (no-op on fresh installs).
bash "$HOME/.local/share/mtls-hello/scripts/migrate-layout.sh" "$HOME/.local/share/mtls-hello" "$HOST" || true

# Vendor runtime libraries so the binary runs without the Nix shell. The D
# binary links against OpenSSL and zlib from the Nix store; copy those into the
# install tree and let the systemd service use LD_LIBRARY_PATH to find them.
mkdir -p "$HOME/.local/lib/mtls-hello"
for lib in libssl.so.3 libcrypto.so.3 libz.so.1; do
  src=$(ldd "$binary" | awk -v libname="$lib" '$1 == libname { print $3 }')
  if [ -n "$src" ] && [ -f "$src" ]; then
    remove_file_safe "$HOME/.local/lib/mtls-hello/$lib"
    cp -L "$src" "$HOME/.local/lib/mtls-hello/$lib"
  fi
done

echo "Installed mtls-hello to $HOME/.local/bin/mtls-hello"
echo "Installed handlers to $HOME/.local/share/mtls-hello/handlers/"
echo "Installed discovery callback to $HOME/.local/share/mtls-hello/scripts/on-discovery.d/ (numbered scripts, lex run by _run-parts.sh)"
echo "Installed hook templates (*.new) to $HOME/.local/share/mtls-hello/scripts/"
echo "Installed certificates to $HOME/.local/share/mtls-hello/identity/"
echo "Vendored runtime libs to $HOME/.local/lib/mtls-hello/"
echo
echo "Generating Apache site configuration..."
DATA_DIR="$HOME/.local/share/mtls-hello"
HOST_FN="$(printf '%s' "$(hostname)" | tr -c 'A-Za-z0-9._-' '_')"
bash "$DATA_DIR/scripts/apache-config.sh" "$DATA_DIR" "${MTLS_PORT:-8443}" \
    "$DATA_DIR/identity/$HOST_FN.crt" "$DATA_DIR/identity/$HOST_FN.key" \
    "$DATA_DIR/apache/httpd.conf"
echo "Installed Apache config to $DATA_DIR/apache/httpd.conf"
echo
echo "To activate a hook: cp <name>.new <name> && chmod +x <name>"
echo "Re-running install overwrites .new files but preserves your custom files."
echo
echo "If ~/.local/bin is not on your PATH, add:"
# shellcheck disable=SC2016
# The advice is meant to be copied literally; $HOME should not expand here.
echo '  export PATH="$HOME/.local/bin:$PATH"'
echo
echo "To enable discovery-triggered sync, set:"
# shellcheck disable=SC2016
# The advice is meant to be copied literally; $HOME should not expand here.
echo '  export CALLBACK_SCRIPT="$HOME/.local/share/mtls-hello/scripts/on-discovery.d/_run-parts.sh"'
echo "(Required — the server has no default path for CALLBACK_SCRIPT.)"
