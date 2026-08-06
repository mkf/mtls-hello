#!/usr/bin/env bash
# handlers/nncp-receive.post.sh - CGI handler invoked by Apache at
# POST /nncp/receive/. Reads an NNCP-format outer packet from stdin,
# validates against the per-host mTLS trust gate (feature 023), writes
# the body into <data-dir>/nncp/queues/<self-id>/inbound/, then runs
# nncp-toss which honours all three per-area roles (full-subscriber /
# relay-only / unconfigured) natively via toss.go:802-973.
#
# This script does NOT understand NNCP packet structure — that is
# exclusively nncp-toss's job. We only:
#   1. Resolve DATA_DIR from MTLS_DATA_DIR (Apache SetEnv) or fall back
#      to $HOME/.local/share/mtls-hello.
#   2. Trust-gate via scripts/cgi-trust.sh is_trusted().
#   3. Read body to a tempfile.
#   4. Hand off to <bin>/nncp-toss.
#
# Output: Apache CGI Status: header plus optional body. Exit code:
#   * 202 Accepted        — toss succeeded (forwarded/subscriber-decrypted/seen-marked).
#   * 401 Unauthorized    — mTLS gate failed (peer cert missing or fingerprint mismatch).
#   * 403 Forbidden       — CN-vs-URL-prefix mismatch (rare; URL is /nncp/receive/ only).
#   * 409 Conflict        — body file could not be moved into inbound/.
#   * 500 Internal       — handler bug (e.g., nncp.hjson missing self.id).
#   * 501 Not Implemented — nncp-toss binary absent.
#   * 502 Bad Gateway     — nncp-toss exited non-zero (packet error / storage error).

set -euo pipefail

DATA_DIR="${MTLS_DATA_DIR:-}"
TRUST_DIR="${MTLS_TRUST_DIR:-}"

if [ -z "$DATA_DIR" ] || [ ! -d "$DATA_DIR" ]; then
    DATA_DIR="${HOME}/.local/share/mtls-hello"
fi
if [ -z "$TRUST_DIR" ] || [ ! -d "$TRUST_DIR" ]; then
    TRUST_DIR="$DATA_DIR/hosts"
fi

# Source shared helpers. Use known locations: prefer project-local <repo>/scripts,
# then user's install-prefix; both modes supported for BATS unit-test callers.
SCRIPT_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
for d in "$PROJECT_ROOT/scripts" "$DATA_DIR/scripts"; do
    [ -r "$d/cgi-trust.sh" ]   && . "$d/cgi-trust.sh"   && [ -r "$d/cgi-trust.sh" ]   && break
done >/dev/null 2>&1 || true
# Re-source explicitly so we definitely pick them up.
. "$DATA_DIR/scripts/cgi-trust.sh" 2>/dev/null || . "$PROJECT_ROOT/scripts/cgi-trust.sh"
. "$DATA_DIR/scripts/cgi-common.sh" 2>/dev/null || . "$PROJECT_ROOT/scripts/cgi-common.sh"
. "$DATA_DIR/scripts/cleanup-common.sh" 2>/dev/null || . "$PROJECT_ROOT/scripts/cleanup-common.sh"

# Trust gate: per-host mTLS fingerprint match (feature 023 mechanism).
if ! is_trusted "$TRUST_DIR"; then
    cn="$(cgi_client_hostname 2>/dev/null || echo unknown)"
    cgi_error "401 Unauthorized" "nncp-receive: peer ${cn} not in trust store"
fi

# Determine which nncp-toss to invoke: prefer the per-data-dir install, then
# PATH. We do NOT install globally.
NNCP_TOSS="$DATA_DIR/bin/nncp-toss"
[ -e "$NNCP_TOSS" ] || NNCP_TOSS="$(command -v nncp-toss 2>/dev/null || true)"
if [ -z "$NNCP_TOSS" ] || [ ! -f "$NNCP_TOSS" ]; then
    cgi_error "501 Not Implemented" "nncp-receive: nncp-toss not found; feature disabled"
fi

# Resolve self.id from <data-dir>/nncp.hjson self.id.
NNCP_HJSON="$DATA_DIR/nncp.hjson"
SELF_ID="$(awk -F'"' '/^self:/,/^}/ { if ($2 == "id") print $4 }' "$NNCP_HJSON" 2>/dev/null || true)"
if [ -z "$SELF_ID" ]; then
    cgi_error "500 Internal Server Error" "nncp-receive: $NNCP_HJSON self.id missing"
fi

# SPOOL: <data-dir>/nncp/queues/<self-id>/inbound/
SPOOL="$DATA_DIR/nncp/queues"
INBOUND="$SPOOL/$SELF_ID/inbound"
mkdir -p -- "$SPOOL" "$INBOUND"

# Read body into a temp file under inbound/. Filename starts with "ni." so
# nncp-toss-pathspec catch-all glob (the binary's own file pattern match)
# picks it up; the unique-12-hex suffix is mktemp's default.
ID_FILE="$(mktemp "${INBOUND}/ni.XXXXXXXX")"
STDERR_FILE="$(mktemp "${DATA_DIR}/run/nncp-receive.stderr.XXXXXXXX")"
trap 'remove_file_safe "$ID_FILE" "$STDERR_FILE" 2>/dev/null; rmdir "${STDERR_FILE%/*}" 2>/dev/null || true' EXIT

if ! cat > "$ID_FILE"; then
    cgi_error "409 Conflict" "nncp-receive: body write to $ID_FILE failed"
fi

# Hand-off to nncp-toss. Filter flags to "-seen -noack -nofile -noexec -nofreq -notrns"
# so we don't surprises-process "file" / "exec" packets out of the inbound queue
# (those belong on the TCP/listener path). "area" packets DO get forwarded by
# default — full subscriber decrypts, relay-only forwards, unconfigured logs and
# drops (see /tmp/nncp-8.13.0/src/toss.go:802-973 and doc/cfg/areas.texi).
set +e
"$NNCP_TOSS" \
    -cfg  "$NNCP_HJSON" \
    -spool "$SPOOL" \
    -seen \
    -noack \
    -nofile \
    -noexec \
    -nofreq \
    -notrns \
    2>"$STDERR_FILE"
rc=$?
set -e

case "$rc" in
    0)
        echo "Status: 202 Accepted"
        echo "Content-Type: text/plain"
        echo
        echo "nncp-receive: tossed $(basename -- "$ID_FILE") via $NNCP_TOSS"
        ;;
    1)
        stderr_trim="$(head -c 4096 "$STDERR_FILE" 2>/dev/null || true)"
        cgi_error "502 Bad Gateway" "nncp-receive: nncp-toss packet error: ${stderr_trim:-no stderr}"
        ;;
    2)
        stderr_trim="$(head -c 4096 "$STDERR_FILE" 2>/dev/null || true)"
        cgi_error "502 Bad Gateway" "nncp-receive: nncp-toss storage error: ${stderr_trim:-no stderr}"
        ;;
    *)
        stderr_trim="$(head -c 4096 "$STDERR_FILE" 2>/dev/null || true)"
        cgi_error "502 Bad Gateway" "nncp-receive: nncp-toss exited $rc: ${stderr_trim:-no stderr}"
        ;;
esac
