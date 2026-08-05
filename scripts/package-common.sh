#!/usr/bin/env bash
# Shared build + staging logic for native distro packages.
# Sourced by package-debian.sh and package-arch.sh (and copied into the
# Docker build containers). Provides:
#   check_build_deps     — verify ldc2/dub are available
#   build_binary         — dub build the server binary
#   stage_install_tree   — lay out the system-wide install tree under a root
#   write_systemd_unit   — write the systemd user unit to a path
#   generate_cert        — postinst-style self-signed cert generation
#
# No Guix. Builds natively with the host's ldc + dub.
set -euo pipefail

# Read the project version from dub.json.
project_version() {
    sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' dub.json | head -1
}

# Read the project description from dub.json.
project_description() {
    sed -n 's/.*"description": *"\([^"]*\)".*/\1/p' dub.json | head -1
}

# Verify the build toolchain is present.
check_build_deps() {
    local missing=0
    if ! command -v ldc2 >/dev/null 2>&1; then
        echo "Error: ldc2 (D compiler) not found. Install the 'ldc' package." >&2
        missing=1
    fi
    if ! command -v dub >/dev/null 2>&1; then
        echo "Error: dub (D package manager) not found. Install the 'dub' package." >&2
        missing=1
    fi
    if [ "$missing" -ne 0 ]; then
        exit 1
    fi
}

# Build the server binary from source.
build_binary() {
    bash scripts/version.sh
    # DC env var is required by the openssl dub package's preGenerateCommands.
    # --compiler=ldc2 is the explicit compiler selection.
    DC=ldc2 dub build --compiler=ldc2
}

# Write the systemd user unit to $1 (absolute path).
# Uses per-user paths (%h) so the user service can read its own certs.
# Cert generation happens on first start via ExecStartPre (runs as the user).
write_systemd_unit() {
    local unit_path="$1"
    mkdir -p "$(dirname "$unit_path")"
    cat > "$unit_path" <<'EOF'
[Unit]
Description=mtls-hello mutual-TLS server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=OUR_CERT=%h/.local/share/mtls-hello/certs/certs/server.crt
Environment=OUR_KEY=%h/.local/share/mtls-hello/certs/private/server.key
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
EOF
}

# Stage the system-wide install tree under $1 (root dir).
# Layout:
#   usr/bin/mtls-hello
#   usr/lib/mtls-hello/handlers/bundle.post.sh
#   usr/lib/mtls-hello/scripts/on-discover.sh
#   usr/lib/mtls-hello/scripts/pre-push.sh.new
#   usr/lib/systemd/user/mtls-hello.service
stage_install_tree() {
    local root="$1"
    mkdir -p "$root/usr/bin" \
             "$root/var/lib/mtls-hello/handlers" \
             "$root/var/lib/mtls-hello/scripts" \
             "$root/usr/lib/systemd/user"

    install -D -m 755 mtls-hello "$root/usr/bin/mtls-hello"
    cp -p handlers/bundle.post.sh "$root/var/lib/mtls-hello/handlers/"
    cp -p scripts/on-discover.sh "$root/var/lib/mtls-hello/scripts/"
    cp -p scripts/trust-host.sh "$root/var/lib/mtls-hello/scripts/"
    cp -p scripts/pre-push.sh.new "$root/var/lib/mtls-hello/scripts/"

    # Cert-generation helper called by the systemd unit's ExecStartPre.
    # Generates a self-signed cert at ~/.local/share/mtls-hello/certs/ if missing.
    cat > "$root/var/lib/mtls-hello/scripts/gen-cert.sh" <<'GENCERT'
#!/usr/bin/env bash
set -e
cert_dir="$HOME/.local/share/mtls-hello/certs/certs"
key_dir="$HOME/.local/share/mtls-hello/certs/private"
mkdir -p "$cert_dir" "$key_dir"
if [ ! -f "$cert_dir/server.crt" ]; then
    if openssl version >/dev/null 2>&1; then
        hostname_val="$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo localhost)"
        openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
            -keyout "$key_dir/server.key" \
            -out "$cert_dir/server.crt" \
            -subj "/CN=$hostname_val" >/dev/null 2>&1
        chmod 600 "$key_dir/server.key"
        echo "Generated self-signed server certificate for $hostname_val"
    else
        echo "Warning: openssl not found; cannot generate certificate." >&2
    fi
fi
GENCERT
    chmod 755 "$root/var/lib/mtls-hello/scripts/gen-cert.sh"

    write_systemd_unit "$root/usr/lib/systemd/user/mtls-hello.service"
}

# Post-install: generate a self-signed server certificate if none exists.
# Called by the Debian postinst and Arch .INSTALL scripts.
# Cert lives at /var/lib/mtls-hello/certs/{certs/server.crt, private/server.key}.
generate_cert() {
    local cert_dir="/var/lib/mtls-hello/certs/certs"
    local key_dir="/var/lib/mtls-hello/certs/private"
    mkdir -p "$cert_dir" "$key_dir"
    if [ ! -f "$cert_dir/server.crt" ]; then
        if ! openssl version >/dev/null 2>&1; then
            echo "Warning: openssl not found; cannot generate self-signed server certificate." >&2
            echo "Install openssl or provide certificates manually." >&2
        else
            openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
                -keyout "$key_dir/server.key" \
                -out "$cert_dir/server.crt" \
                -subj "/CN=$(hostname)" >/dev/null 2>&1
            chmod 600 "$key_dir/server.key"
            echo "Generated self-signed server certificate for $(hostname)"
        fi
    fi
}
