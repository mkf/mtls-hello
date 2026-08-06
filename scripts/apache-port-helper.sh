#!/bin/bash
# Wait for Apache to report its listening port and write it to a file.
# Usage: apache-port-helper.sh <data-dir> <port-or-zero> [port-file]
set -euo pipefail

if [ "$#" -lt 2 ]; then
    echo "Usage: $0 <data-dir> <port-or-zero> [port-file]" >&2
    exit 1
fi

DATA_DIR="$1"
PORT="$2"
PORT_FILE="${3:-$DATA_DIR/apache/port}"
ERROR_LOG="$DATA_DIR/apache/error.log"

mkdir -p "$(dirname "$PORT_FILE")"

if [ "$PORT" != "0" ]; then
    echo "$PORT" > "$PORT_FILE"
    echo "$PORT"
    exit 0
fi

# For Listen 0, Apache logs a line like:
#   (98)Address already in use: AH00072: make_sock: could not bind to address [::]:0
# or on success:
#   Command line: '/usr/sbin/httpd-prefork -f ...'
# We wait for a line that contains "Configured -- resuming normal operations" or similar,
# then read the actual port from the first "listening on ..." line if available.
for _i in $(seq 1 300); do
    if [ -f "$ERROR_LOG" ]; then
        # Apache logs the actual port in lines like:
        #   [mpm_...:notice] ... AH00163: Apache/... configured -- resuming normal operations
        # The port is not directly logged, but we can infer it from the Listen 0 behavior.
        # As a fallback, read the port from the Apache scoreboard or a separate probe.
        if grep -qE "configured -- resuming normal operations" "$ERROR_LOG"; then
            break
        fi
    fi
    sleep 0.1
done

# If we still don't know the port, probe the common ephemeral range. This is a best-effort
# fallback for random-port mode; production use should prefer a fixed port or read the
# port from the service unit.
for probe in $(seq 1024 65535); do
    if (exec 5<>"/dev/tcp/127.0.0.1/$probe") 2>/dev/null; then
        exec 5>&- 5<&- 2>/dev/null || true
        echo "$probe" > "$PORT_FILE"
        echo "$probe"
        exit 0
    fi
done

echo "Could not determine Apache port" >&2
exit 1
