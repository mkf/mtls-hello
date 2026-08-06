#!/bin/bash
# Shared CGI utilities for Apache handlers.
# Sourced by handler scripts; not executed directly.

# Parse QUERY_STRING into QUERY_<KEY> variables (uppercase, matching the
# convention used by the previous vibe.d server).
# Example: QUERY_STRING="repo=laptops&host=peer1" sets QUERY_REPO and QUERY_HOST.
cgi_parse_query() {
    local qs="${QUERY_STRING:-}"
    local IFS='&'
    local pair key val upper
    for pair in $qs; do
        key="${pair%%=*}"
        val="${pair#*=}"
        # URL-decode: replace + with space and %XX with bytes.
        val="${val//+/ }"
        val=$(printf '%b' "${val//%/\\x}")
        # Uppercase the key and prefix with QUERY_.
        upper=$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]' | tr -c '[:alnum:]' '_')
        [ -n "$upper" ] && eval "QUERY_${upper}=\$val"
    done
}

# Emit a CGI response header and blank line.
# Usage: cgi_header [content-type]
cgi_header() {
    echo "Content-Type: ${1:-text/plain}"
    echo ""
}

# Emit a CGI error response with a status code.
# Usage: cgi_error <status_code> <message>
cgi_error() {
    echo "Status: $1"
    echo "Content-Type: text/plain"
    echo ""
    echo "$2"
    exit 0
}

# Resolve <data-dir> from env (MTLS_DATA_DIR set by Apache SetEnv), with
# sane fallbacks for unit-test invocations (no Apache in CI).
data_dir_resolve() {
    local d="${MTLS_DATA_DIR:-}"
    if [ -n "$d" ] && [ -d "$d" ]; then
        echo "$d"
        return 0
    fi
    d="${DATA_DIR:-}"
    if [ -n "$d" ] && [ -d "$d" ]; then
        echo "$d"
        return 0
    fi
    echo "${HOME}/.local/share/mtls-hello"
}

# Atomically merge a peer entry into <data-dir>/nncp.hjson's `neigh:` map.
# Usage: nncp_hjson_set_neigh <hjson-path> <peer-name> <id> <exchpub> <signpub> [noisepub]
# Strategy:
#   1. Emit the existing file through cat into the rendered target.
#   2. Use awk to splice in (or replace) the `neigh.<peer-name>` block.
# That is intentionally lightweight: we do not need a full hjson parser,
# and Apache's downstream NNCP binary's hjson-go accepts our symmetric format
# (string scalars, simple map with quoted keys).
nncp_hjson_set_neigh() {
    local hjson="$1" peer_name="$2" peer_id="$3" exchpub="$4" signpub="$5"
    local noisepub="${6:-}"
    local tmp
    tmp="$(mktemp "${hjson}.XXXX")"
    # shellcheck disable=SC2310  # mktemp returns a real path
    if [ ! -f "$hjson" ]; then
        # Fresh file: scaffold the bare minimum NNCP accepts.
        {
            echo "self: {"
            echo "}"
            echo "neigh: {"
            [ -n "$noisepub" ] && np_field=", \"noisepub\": \"$noisepub\""
            echo "  \"$peer_name\": { \"id\": \"$peer_id\", \"exchpub\": \"$exchpub\", \"signpub\": \"$signpub\"$np_field }"
            echo "}"
        } > "$tmp"
        mv -- "$tmp" "$hjson"
        return 0
    fi
    # Idempotent: replace existing entry's block; create `neigh:` map if absent;
    # otherwise leave other entries untouched. Uses awk because it's a single-pass
    # text transformer that's available everywhere.
    awk -v peer="$peer_name" -v id="$peer_id" -v exch="$exchpub" \
        -v sign="$signpub" -v noise="$noisepub" '
        BEGIN { in_neigh = 0; wrote_peer = 0 }
        /^neigh:[[:space:]]*\{/ { print; in_neigh = 1; next }
        in_neigh == 1 && /^}/ {
            if (wrote_peer == 0) {
                printf("  \"%s\": { \"id\": \"%s\", \"exchpub\": \"%s\", \"signpub\": \"%s\"", peer, id, exch, sign)
                if (noise != "") printf(", \"noisepub\": \"%s\"", noise)
                print " }"
                wrote_peer = 1
            }
            print; in_neigh = 0
            next
        }
        in_neigh == 1 {
            # Detect existing entry for this peer; replace it.
            line = $0
            if (line ~ "^[[:space:]]*\"" peer "\":[[:space:]]*\{") {
                # Skip until matching closing brace.
                depth = 1
                while ((getline line) > 0) {
                    nopen = gsub(/\{/, "{", line)
                    nclose = gsub(/\}/, "}", line)
                    depth += nopen - nclose
                    if (depth <= 0) break
                }
            } else {
                print
            }
            next
        }
        {
            wrote_neigh = 0
            print
        }
        END {
            # Scaffolding path: if we still have not produced a neigh map, inject one.
        }
    ' "$hjson" > "$tmp"
    # If the original file had no `neigh:` block, awk left the file unchanged in
    # that respect; inject the map now.
    if ! grep -q '^neigh:' "$tmp"; then
        {
            echo "" >> "$tmp"
            echo "neigh: {" >> "$tmp"
            [ -n "$noisepub" ] && np_field=", \"noisepub\": \"$noisepub\""
            echo "  \"$peer_name\": { \"id\": \"$peer_id\", \"exchpub\": \"$exchpub\", \"signpub\": \"$signpub\"$np_field }" >> "$tmp"
            echo "}" >> "$tmp"
        }
    fi
    mv -- "$tmp" "$hjson"
}
