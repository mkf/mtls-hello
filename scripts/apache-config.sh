#!/bin/bash
# Generate a self-contained Apache httpd.conf for the project.
# Usage: apache-config.sh <data-dir> <port> <server-cert> <server-key> <output-file>
set -euo pipefail

if [ "$#" -ne 5 ]; then
    echo "Usage: $0 <data-dir> <port> <server-cert> <server-key> <output-file>" >&2
    exit 1
fi

DATA_DIR="$1"
PORT="$2"
SERVER_CERT="$3"
SERVER_KEY="$4"
OUTPUT="$5"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SITE_TEMPLATE="$PROJECT_ROOT/config/apache-site.conf.in"

if [ ! -f "$SITE_TEMPLATE" ]; then
    echo "Apache site template not found: $SITE_TEMPLATE" >&2
    exit 1
fi

HOST_NAME="${HOST_NAME:-$(hostname)}"
SCRIPT_TIMEOUT="${MTLS_SCRIPT_TIMEOUT:-10}"

mkdir -p "$(dirname "$OUTPUT")"
mkdir -p "$DATA_DIR/apache"

# Discover the Apache module directory from common paths.
find_module_dir() {
    local d
    for d in \
        "${APACHE_MODULE_DIR:-}" \
        /usr/lib64/apache2-prefork \
        /usr/lib/apache2/modules \
        /usr/lib/httpd/modules \
        /usr/lib64/apache2 \
        /usr/lib/apache2 \
        /usr/libexec/apache2 \
        /opt/local/lib/apache2/modules
    do
        if [ -d "$d" ] && [ -f "$d/mod_ssl.so" ]; then
            echo "$d"
            return 0
        fi
    done
    return 1
}

find_mpm_module() {
    local d="$1"
    for m in mod_mpm_event.so mod_mpm_prefork.so mod_mpm_worker.so; do
        if [ -f "$d/$m" ]; then
            echo "$m"
            return 0
        fi
    done
    return 1
}

has_module() {
    local d="$1" m="$2"
    [ -f "$d/$m" ]
}

MOD_DIR="$(find_module_dir)"
if [ -z "$MOD_DIR" ]; then
    echo "Could not find Apache module directory (checked common paths)." >&2
    echo "Set APACHE_MODULE_DIR to the directory containing mod_ssl.so." >&2
    exit 1
fi

SITE_CONF="$DATA_DIR/apache/site.conf"

sed \
    -e "s|{{PORT}}|$PORT|g" \
    -e "s|{{DATA_DIR}}|$DATA_DIR|g" \
    -e "s|{{SERVER_CERT}}|$SERVER_CERT|g" \
    -e "s|{{SERVER_KEY}}|$SERVER_KEY|g" \
    -e "s|{{TRUST_DIR}}|$DATA_DIR/hosts|g" \
    -e "s|{{PURGATORY_DIR}}|$DATA_DIR/purgatory|g" \
    -e "s|{{HANDLERS_DIR}}|$DATA_DIR/handlers|g" \
    -e "s|{{HOST_NAME}}|$HOST_NAME|g" \
    -e "s|{{SCRIPT_TIMEOUT}}|$SCRIPT_TIMEOUT|g" \
    "$SITE_TEMPLATE" > "$SITE_CONF"

MPM_MODULE=""
if MPM_MODULE="$(find_mpm_module "$MOD_DIR")"; then
    : # found
else
    MPM_MODULE=""
fi
CGI_MODULE="mod_cgid.so"
if ! has_module "$MOD_DIR" "$CGI_MODULE"; then
    CGI_MODULE="mod_cgi.so"
fi

mkdir -p "$DATA_DIR/apache/mime"
if [ -f /etc/mime.types ]; then
    cp /etc/mime.types "$DATA_DIR/apache/mime/mime.types"
fi

module_name_for_file() {
    local file="$1"
    # mod_foo.so -> foo_module
    basename "$file" .so | sed 's/^mod_//' | sed 's/$/_module/'
}

load_module_line() {
    local file="$1" name
    if [ -f "$file" ]; then
        name="$(module_name_for_file "$file")"
        echo "LoadModule $name \"$file\""
    fi
}

cat > "$OUTPUT" <<EOF
ServerRoot "$DATA_DIR/apache"
Listen $PORT
PidFile "$DATA_DIR/apache/httpd.pid"
ErrorLog "$DATA_DIR/apache/error.log"
CustomLog "$DATA_DIR/apache/access.log" combined
LogLevel warn

EOF

if [ -n "$MPM_MODULE" ]; then
    load_module_line "$MOD_DIR/$MPM_MODULE" >> "$OUTPUT"
fi

{
    load_module_line "$MOD_DIR/mod_authn_file.so"
    load_module_line "$MOD_DIR/mod_authz_core.so"
    load_module_line "$MOD_DIR/mod_reqtimeout.so"
    load_module_line "$MOD_DIR/mod_filter.so"
    load_module_line "$MOD_DIR/mod_mime.so"
    load_module_line "$MOD_DIR/mod_log_config.so"
    load_module_line "$MOD_DIR/mod_env.so"
    load_module_line "$MOD_DIR/mod_headers.so"
    load_module_line "$MOD_DIR/mod_setenvif.so"
    load_module_line "$MOD_DIR/mod_version.so"
    load_module_line "$MOD_DIR/mod_unixd.so"
    load_module_line "$MOD_DIR/$CGI_MODULE"
    load_module_line "$MOD_DIR/mod_alias.so"
    load_module_line "$MOD_DIR/mod_ssl.so"
    load_module_line "$MOD_DIR/mod_rewrite.so"
} >> "$OUTPUT"

cat >> "$OUTPUT" <<EOF

TypesConfig "$DATA_DIR/apache/mime/mime.types"
DefaultType text/plain

Include "$SITE_CONF"
EOF

echo "Generated Apache httpd.conf: $OUTPUT"
