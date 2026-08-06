#!/usr/bin/env bash
# scripts/on-discovery.d/_run-parts.sh - launcher for feature 025's
# discovery-callback directory tree. Invoked by `source/app.d:78` via the
# resolved CALLBACK_SCRIPT env var:
#   <data-dir>/scripts/on-discovery.d/_run-parts.sh
#
# This launcher:
#   1. Resolves <Data-DIR> from $0;
#   2. Pre-computes the peer's NNCP identity (id, signpub, exchpub, noisepub)
#      from $PEER_CERT_FILE; these are inherited by every numbered sub-script.
#   3. Iterates `[0-9][0-9]-*.sh` (alphanumeric lex order) and invokes each via
#      `timeout --kill-after=5 $TIMEOUT bash <script>`. A non-zero exit is
#      logged but does NOT abort the chain (FR-015).
#   4. The 00-validate.sh sub-script may explicitly abort by `exit 254`
#      — that signal short-circuits the rest of the chain (used as the
#      "this peer is not legitimate" gate).
#
# Per the project's safety rule (G1): never `rm -rf` / `find -delete`.
# We never delete anything from the discoverer's directory tree.

set -euo pipefail

# Resolve <data-dir> from this script's path: this lives at
# <data-dir>/scripts/on-discovery.d/_run-parts.sh, so two levels up is <data-dir>.
SCRIPT_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
export DATA_DIR

DIR="$SCRIPT_DIR"  # the on-discovery.d/ dir itself
LOG_PREFIX="[on-discovery.d]"
mkdir -p "$DATA_DIR/queues" "$DATA_DIR/discoveries.log.dir.tmp" 2>/dev/null || true

# Pre-compute NNCP identity from $PEER_CERT_FILE — runs BEFORE the chain so
# every sub-script sees these env vars. The `peer_extract` function lives
# in scripts/cgi-trust.sh.
. "$DATA_DIR/scripts/cgi-trust.sh" 2>/dev/null || {
    echo "$LOG_PREFIX warning: scripts/cgi-trust.sh disappeared; running chain with empty NNCP-identity" >&2
}

PEER_CERT_FILE="${PEER_CERT_FILE:-}"
if [ -n "$PEER_CERT_FILE" ] && [ -f "$PEER_CERT_FILE" ]; then
    if ! peer_extract "$PEER_CERT_FILE"; then
        # Not an Ed25519 cert / legacy RSA + mTLS gates do not let us derive
        # NNCP keys from the cert directly. Set empty fallbacks so the
        # downstream scripts see well-defined values.
        PEER_NNCP_ID=""
        PEER_SIGNPUB=""
        PEER_EXCHPUB=""
        PEER_NOISEPUB=""
        echo "$LOG_PREFIX note: PEER_CERT_FILE=$PEER_CERT_FILE is not Ed25519; NNCP neighbor registration will be skipped" >&2
    fi
else
    PEER_NNCP_ID=""
    PEER_SIGNPUB=""
    PEER_EXCHPUB=""
    PEER_NOISEPUB=""
fi
export PEER_NNCP_ID PEER_SIGNPUB PEER_EXCHPUB PEER_NOISEPUB
export STAGE="${STAGE:-new}"  # "new" or "updated" — set by cgi-trust.peer's stage check
export TIMEOUT="${TIMEOUT:-30}"

# Iterate over [0-9][0-9]-*.sh in lex order. We deliberately exclude any script
# whose basename starts with `_` (this launcher itself), so the launcher is
# not self-reentrant.
ran=""
for script in "$DIR"/[0-9][0-9]-*.sh; do
    [ -e "$script" ] || continue
    base="$(basename -- "$script")"
    echo "$LOG_PREFIX + $base (timeout=${TIMEOUT}s)"
    if ! timeout --kill-after=5 "${TIMEOUT}" env \
            DATA_DIR="$DATA_DIR" \
            TIMEOUT="$TIMEOUT" \
            STAGE="$STAGE" \
            PEER_CERT_FILE="$PEER_CERT_FILE" \
            BASH_SOURCE[0]="$script" \
            bash "$script"; then
        rc=$?
        if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
            echo "$LOG_PREFIX ! $base timed out after ${TIMEOUT}s"
        elif [ "$rc" -eq 254 ]; then
            echo "$LOG_PREFIX ! $base aborted the chain (exit 254)"
            break
        else
            echo "$LOG_PREFIX ! $base exited $rc"
        fi
    else
        ran="$ran $base"
    fi
done

rmdir "$DATA_DIR/discoveries.log.dir.tmp" 2>/dev/null || true

exit 0
