#!/usr/bin/env bats
# Apache-backed mTLS tests (feature 018).
# These tests start their own Apache instance and do not rely on the legacy D HTTP server.

# Safe-deletion helpers (no rm -rf / rm -f anywhere).
# shellcheck source=scripts/cleanup-common.sh
. scripts/cleanup-common.sh

# Wait (up to 3s) for a captured purgatory file to appear; capture is
# asynchronous (piped logger writes after the response). Prints the file list.
_wait_for_purgatory() {
    local dir="$1" pat="${2:-*}" i
    for i in $(seq 1 30); do
        local f
        f=$(ls "$dir"/$pat 2>/dev/null | head -1)
        [ -n "$f" ] && { echo "$f"; return 0; }
        sleep 0.1
    done
    return 1
}

# Remove a scratch cert dir containing only the certs we generated.
_remove_cert_dir() {
    local dir="$1"
    remove_file_safe "$dir"/*.crt "$dir"/*.key
    rmdir -- "$dir" || echo "warning: could not rmdir $dir" >&2
}

# Remove a scratch Apache data dir (known layout).
_remove_apache_dd() {
    local dir="$1"
    [ -d "$dir" ] || return 0
    remove_file_safe "$dir"/apache/httpd.conf "$dir"/apache/site.conf "$dir"/apache/error.log "$dir"/apache/access.log "$dir"/apache/httpd.pid
    remove_file_safe "$dir"/apache/mime/mime.types
    rmdir -- "$dir"/apache/mime "$dir"/apache 2>/dev/null || true
    remove_file_safe "$dir"/handlers/* "$dir"/scripts/* "$dir"/hosts/* "$dir"/purgatory/* "$dir"/repos/*
    local d
    for d in "$dir"/handlers "$dir"/scripts "$dir"/hosts "$dir"/purgatory "$dir"/repos; do
        [ -d "$d" ] || continue
        rmdir -- "$d" || echo "warning: could not rmdir $d" >&2
    done
    rmdir -- "$dir" || echo "warning: could not rmdir $dir" >&2
}

setup_file() {
    export PATH="/usr/sbin:$PATH"
}

teardown_file() {
    # Kill any leftover Apache processes from our tests.
    pkill -f 'httpd.*-f /tmp/tmp\.' 2>/dev/null || true
}

# Helper: find an available Apache binary.
_find_apache() {
    command -v httpd-prefork >/dev/null 2>&1 && echo "httpd-prefork" && return 0
    command -v httpd >/dev/null 2>&1 && echo "httpd" && return 0
    command -v apache2 >/dev/null 2>&1 && echo "apache2" && return 0
    return 1
}

# Helper: start Apache and wait for the port to be ready.
# Sets global APACHE_PID and APACHE_DD.
_start_apache() {
    local cert_dir="$1" port="$2" handler="$3"
    APACHE_DD="$(mktemp -d)"
    mkdir -p "$APACHE_DD/handlers" "$APACHE_DD/hosts" "$APACHE_DD/purgatory" "$APACHE_DD/scripts"
    cp "handlers/$handler" "$APACHE_DD/handlers/"
    cp scripts/cgi-lib.sh scripts/log-capture.sh "$APACHE_DD/scripts/"
    chmod +x "$APACHE_DD/handlers/$handler"
    bash scripts/apache-config.sh "$APACHE_DD" "$port" \
        "$cert_dir/server.crt" "$cert_dir/server.key" "$APACHE_DD/apache/httpd.conf"
    "$APACHE_BIN" -f "$APACHE_DD/apache/httpd.conf" >/dev/null 2>&1 &
    APACHE_PID=$!
    local _i
    for _i in $(seq 1 50); do
        if (exec 6<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
            exec 6>&- 6<&- 2>/dev/null || true
            return 0
        fi
        kill -0 "$APACHE_PID" 2>/dev/null || {
            echo "Apache died. Error log:" >&2
            cat "$APACHE_DD/apache/error.log" >&2 || true
            return 1
        }
        sleep 0.1
    done
    echo "Apache did not become ready on port $port" >&2
    cat "$APACHE_DD/apache/error.log" >&2 || true
    return 1
}

_stop_apache() {
    if [ -n "${APACHE_PID:-}" ]; then
        pkill -P "$APACHE_PID" 2>/dev/null || true
        kill "$APACHE_PID" 2>/dev/null || true
        sleep 0.3
        pkill -9 -P "$APACHE_PID" 2>/dev/null || true
        kill -9 "$APACHE_PID" 2>/dev/null || true
    fi
    _remove_apache_dd "${APACHE_DD:-}"
}

@test "US1: Apache requests client cert and exposes it to CGI" {
    APACHE_BIN="$(_find_apache)" || skip "Apache binary not available"
    local cert_dir port
    cert_dir="$(mktemp -d)"
    port=18680
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
        -keyout "$cert_dir/server.key" -out "$cert_dir/server.crt" \
        -subj /CN=localhost -addext "basicConstraints=CA:FALSE" >/dev/null 2>&1
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
        -keyout "$cert_dir/client.key" -out "$cert_dir/client.crt" \
        -subj /CN=test-client -addext "basicConstraints=CA:FALSE" >/dev/null 2>&1

    _start_apache "$cert_dir" "$port" "cert-echo.get.sh" || {
        echo "Apache failed to start" >&2
        return 1
    }

    run curl -sS --max-time 5 \
        --cacert "$cert_dir/server.crt" \
        --cert "$cert_dir/client.crt" --key "$cert_dir/client.key" \
        "https://localhost:$port/cert-echo.get.sh"

    [ "$status" -eq 0 ]
    echo "$output" | grep -q "cn=test-client"
    echo "$output" | grep -Eq "fp=[0-9a-f]{64}"
    echo "$output" | grep -q "Untrusted"

    _stop_apache
    _remove_cert_dir "$cert_dir"
}

@test "US2: Apache backend captures untrusted client certificate" {
    APACHE_BIN="$(_find_apache)" || skip "Apache binary not available"
    local cert_dir port
    cert_dir="$(mktemp -d)"
    port=18681
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
        -keyout "$cert_dir/server.key" -out "$cert_dir/server.crt" \
        -subj /CN=localhost -addext "basicConstraints=CA:FALSE" >/dev/null 2>&1
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
        -keyout "$cert_dir/client.key" -out "$cert_dir/client.crt" \
        -subj /CN=test-client -addext "basicConstraints=CA:FALSE" >/dev/null 2>&1

    _start_apache "$cert_dir" "$port" "cert-echo.get.sh" || return 1

    curl -sS --max-time 5 \
        --cacert "$cert_dir/server.crt" \
        --cert "$cert_dir/client.crt" --key "$cert_dir/client.key" \
        "https://localhost:$port/cert-echo.get.sh" >/dev/null 2>&1 || true

    # Purgatory should contain exactly one file for test-client.
    _wait_for_purgatory "$APACHE_DD/purgatory" 'test-client.*.crt' >/dev/null
    [ "$(find "$APACHE_DD/purgatory" -name 'test-client.*.crt' | wc -l)" -eq 1 ]

    _stop_apache
    _remove_cert_dir "$cert_dir"
}

@test "US2: Promoted captured certificate grants trust under Apache" {
    APACHE_BIN="$(_find_apache)" || skip "Apache binary not available"
    local cert_dir port
    cert_dir="$(mktemp -d)"
    port=18682
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
        -keyout "$cert_dir/server.key" -out "$cert_dir/server.crt" \
        -subj /CN=localhost -addext "basicConstraints=CA:FALSE" >/dev/null 2>&1
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
        -keyout "$cert_dir/client.key" -out "$cert_dir/client.crt" \
        -subj /CN=test-client -addext "basicConstraints=CA:FALSE" >/dev/null 2>&1

    _start_apache "$cert_dir" "$port" "cert-echo.get.sh" || return 1

    # First request: untrusted, captures cert.
    curl -sS --max-time 5 \
        --cacert "$cert_dir/server.crt" \
        --cert "$cert_dir/client.crt" --key "$cert_dir/client.key" \
        "https://localhost:$port/cert-echo.get.sh" >/dev/null 2>&1 || true

    # Promote the captured certificate.
    local captured
    captured="$(_wait_for_purgatory "$APACHE_DD/purgatory" 'test-client.*.crt')"
    cp "$captured" "$APACHE_DD/hosts/test-client.crt"

    # Second request: should be trusted now.
    run curl -sS --max-time 5 \
        --cacert "$cert_dir/server.crt" \
        --cert "$cert_dir/client.crt" --key "$cert_dir/client.key" \
        "https://localhost:$port/cert-echo.get.sh"

    [ "$status" -eq 0 ]
    echo "$output" | grep -q "trusted"

    _stop_apache
    _remove_cert_dir "$cert_dir"
}
