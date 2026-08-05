#!/usr/bin/env bash
set -euo pipefail

version=$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' dub.json | head -1)
if [ -z "$version" ]; then
    echo "Error: could not extract version from dub.json" >&2
    exit 1
fi

cat > source/version_.d <<EOF
module version_;
enum appVersion = "${version}";
EOF
