#!/usr/bin/env bash
set -euo pipefail

binary="$HOME/.local/bin/mtls-hello"
if [ ! -f "$binary" ]; then
    echo "Error: $binary not found. Run 'just install' first." >&2
    exit 1
fi

unit_dir="$HOME/.config/systemd/user"
mkdir -p "$unit_dir"

cat > "$unit_dir/mtls-hello.service" <<'EOF'
[Unit]
Description=mtls-hello mutual-TLS server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=LD_LIBRARY_PATH=%h/.local/lib/mtls-hello
Environment=OUR_CERT=%h/.local/share/mtls-hello/certs/certs/server.crt
Environment=OUR_KEY=%h/.local/share/mtls-hello/certs/private/server.key
Environment=REPOS_ROOT=%h/.local/state/REPOS_ROOT
ExecStart=%h/.local/bin/mtls-hello \
  0 \
  --port=0 --port-file=%t/mtls-hello.port \
  --data-dir=%h/.local/share/mtls-hello
ExecStartPost=/bin/sh -c 'echo "mtls-hello listening on port $(cat %t/mtls-hello.port)"'
Restart=on-failure
RestartSec=5s
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
EOF

echo "Service unit installed to $unit_dir/mtls-hello.service"
echo
echo "Next steps:"
echo "  systemctl --user daemon-reload"
echo "  systemctl --user enable --now mtls-hello"
echo
echo "To add certificates and trust paths, create a drop-in override:"
echo "  systemctl --user edit mtls-hello"
