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
Description=mtls-hello discovery daemon
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=LD_LIBRARY_PATH=%h/.local/lib/mtls-hello
Environment=OUR_CERT=%h/.local/share/mtls-hello/identity/%H.crt
Environment=OUR_KEY=%h/.local/share/mtls-hello/identity/%H.key
Environment=REPOS_ROOT=%h/.local/state/REPOS_ROOT
Environment=CALLBACK_SCRIPT=%h/.local/share/mtls-hello/scripts/on-discover.sh
ExecStart=%h/.local/bin/mtls-hello \
  8443 \
  --data-dir=%h/.local/share/mtls-hello
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
