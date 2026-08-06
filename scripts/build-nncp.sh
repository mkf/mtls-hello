#!/usr/bin/env bash
# build-nncp.sh - compile the NNCP 8.13.0 single binary from /tmp/nncp-8.13.0
# and symlink every command name listed in cmd.list.
#
# Why a single Go build:
#   /tmp/nncp-8.13.0/src/cmd/nncp/main.go dispatches every subcommand by
#   `os.Args[0]`'s basename; all 22 subcommands share one entry point.
#   We compile that once and create symlinks for the seven the project
#   actually uses (nncp-toss, nncp-call, nncp-stat, nncp-cfgnew, nncp-cfgmin,
#   nncp-cfgenc, nncp-check).
#
# Usage:
#   scripts/build-nncp.sh --src /tmp/nncp-8.13.0 --dir <data-dir>/bin
#
# Idempotent: re-running with the binary already in place is a no-op (just
# refreshes the symlinks). Per the project's safety rule: no `rm -rf`,
# no `find -delete` — only plain `rm` on known files / `rmdir` on empty
# directories if we ever wipe the .dir between rebuilds.

set -euo pipefail

SRC=""
BIN_DIR=""

while [ $# -gt 0 ]; do
    case "$1" in
        --src) SRC="$2"; shift 2 ;;
        --dir) BIN_DIR="$2"; shift 2 ;;
        -h|--help)
            cat <<USE
usage: build-nncp.sh --src <src-dir> --dir <bin-dir>

Builds /tmp/nncp-8.13.0/src/cmd/nncp into <bin-dir>/nncp and symlinks all
subcommand names from <src-dir>/cmd.list.
USE
            exit 0
            ;;
        *) echo "build-nncp.sh: unknown arg: $1" >&2; exit 2 ;;
    esac
done

[ -n "$SRC" ] || { echo "build-nncp.sh: --src <src-dir> is required" >&2; exit 2; }
[ -n "$BIN_DIR" ] || { echo "build-nncp.sh: --dir <bin-dir> is required" >&2; exit 2; }

[ -d "$SRC/src/cmd/nncp" ] || {
    echo "build-nncp.sh: not the expected layout — missing $SRC/src/cmd/nncp/" >&2
    echo "build-nncp.sh: hint: ensure /tmp/nncp-8.13.0/src/cmd/nncp/main.go is present" >&2
    exit 1
}
[ -f "$SRC/cmd.list" ] || { echo "build-nncp.sh: missing $SRC/cmd.list" >&2; exit 1; }

command -v go >/dev/null 2>&1 || {
    echo "build-nncp.sh: 'go' not on PATH" >&2
    echo "build-nncp.sh: hint: 'nix-shell -p go -c scripts/build-nncp.sh ...' or install Go ≥1.21" >&2
    exit 1
}

mkdir -p "$BIN_DIR"

# Idempotent short-circuit: if the binary already exists and matches the
# source-modtime, skip the rebuild. This keeps `bash scripts/install.sh`
# fast on re-runs. We re-link unconditionally so a freshly-extracted tarball
# whose cmd.list changed picks up new symlinks.
if [ -x "$BIN_DIR/nncp" ]; then
    if [ "$BIN_DIR/nncp" -nt "$SRC/src/cmd/nncp/main.go" ] \
       && [ "$BIN_DIR/nncp" -nt "$SRC/src/toss.go" ] \
       && [ "$BIN_DIR/nncp" -nt "$SRC/src/call.go" ]; then
        echo "build-nncp.sh: $BIN_DIR/nncp is newer than src — skipping rebuild"
        REBUILD_NEEDED=0
    else
        REBUILD_NEEDED=1
    fi
else
    REBUILD_NEEDED=1
fi

if [ "${REBUILD_NEEDED:-1}" -eq 1 ]; then
    # Per build script comment in /tmp/nncp-8.13.0/build: DefaultCfgPath defaults
    # to /etc/nncp.hjson. We don't override it on the linker flag here because
    # nncp-toss accepts -cfg <path> at runtime, so a per-install config works
    # without baking paths into the binary.
    ( cd "$SRC/src" && go build -o "$BIN_DIR/nncp" ./cmd/nncp )
    echo "build-nncp.sh: built $BIN_DIR/nncp"
fi

# Symlink every name in cmd.list.
linked=0
while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    [ "$cmd" = "nncp" ] && continue
    ln -fs nncp "$BIN_DIR/$cmd"
    linked=$((linked + 1))
done < "$SRC/cmd.list"

# Verify the build by running the binary's version flag (silent ignore on failure).
"$BIN_DIR/nncp" -version >/dev/null 2>&1 || true

echo "build-nncp.sh: $BIN_DIR/nncp ready (linked $linked subcommands from $SRC/cmd.list)"
