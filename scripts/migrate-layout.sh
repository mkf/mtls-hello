#!/bin/bash
# Non-interactive migration from the legacy nested `certs/` layout to the flat
# layout:
#
#   certs/certs/server.crt     -> identity/<hostname>.crt
#   certs/private/server.key   -> identity/<hostname>.key
#   certs/hosts/*              -> hosts/
#   certs/purgatory/*          -> purgatory/
#
# Empty legacy directories are removed afterwards. The migration is idempotent,
# never overwrites existing files, never prompts, and never fails on partial or
# unusual legacy layouts.
#
# Usage: migrate-layout.sh <data-dir> [hostname]
set -euo pipefail

DATA_DIR="${1:-}"
HOSTNAME="${2:-$(hostname)}"

if [ -z "$DATA_DIR" ]; then
    echo "migrate-layout: usage: $0 <data-dir> [hostname]" >&2
    exit 2
fi

# Sanitize a hostname into a safe filename: keep [A-Za-z0-9._-], else '_'.
sanitize_hostname() {
    printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'
}

# Move a single file, never overwriting an existing target.
# Returns 0 (moved or nothing to do), 1 (target exists and differs).
move_if_absent() {
    local src="$1" dst="$2"
    [ -f "$src" ] || return 0
    if [ -e "$dst" ]; then
        if ! cmp -s "$src" "$dst"; then
            echo "migrate-layout: keeping existing $dst (differs from $src)" >&2
            return 1
        fi
        return 0
    fi
    mkdir -p "$(dirname "$dst")"
    mv "$src" "$dst"
}

main() {
    local legacy="$DATA_DIR/certs"
    if [ ! -d "$legacy" ]; then
        return 0
    fi

    local safe_hostname
    safe_hostname="$(sanitize_hostname "$HOSTNAME")"

    # 1. Identity (cert + key).
    move_if_absent "$legacy/certs/server.crt" "$DATA_DIR/identity/$safe_hostname.crt" || true
    move_if_absent "$legacy/private/server.key" "$DATA_DIR/identity/$safe_hostname.key" || true

    # 2. Trust store.
    if [ -d "$legacy/hosts" ]; then
        for f in "$legacy"/hosts/*; do
            [ -f "$f" ] || continue
            move_if_absent "$f" "$DATA_DIR/hosts/$(basename "$f")" || true
        done
    fi

    # 3. Purgatory.
    if [ -d "$legacy/purgatory" ]; then
        for f in "$legacy"/purgatory/*; do
            [ -f "$f" ] || continue
            move_if_absent "$f" "$DATA_DIR/purgatory/$(basename "$f")" || true
        done
    fi

    # 4. Remove empty legacy directories (warn on leftovers, never fail).
    local d
    for d in "$legacy/certs" "$legacy/private" "$legacy/hosts" "$legacy/purgatory" "$legacy"; do
        if [ -d "$d" ] && rmdir "$d" 2>/dev/null; then
            :
        elif [ -d "$d" ]; then
            echo "migrate-layout: leaving non-empty directory $d" >&2
        fi
    done
}

main
