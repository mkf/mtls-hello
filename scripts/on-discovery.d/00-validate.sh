#!/usr/bin/env bash
# scripts/on-discovery.d/00-validate.sh — sanity checks at the start of
# every discovery invocation. Refuses to fire the rest of the chain if any
# of the required preconditions fail. Exits 254 to abort the chain.
#
# Required env:
#   HOST_NAME        — friendly name of *this* host (used by 50-bundle-push.sh, 90-log.sh)
#   PEER_NETLOC      — host:port of the peer's mTLS endpoint
#   PEER_CERT_FILE   — path to the peer's mTLS cert
#   OUR_CERT, OUR_KEY — our mTLS client credentials (used by 50-bundle-push.sh / future)
#
# Exit codes:
#   0   — every precondition looks good; chain continues
#   254 — precondition failed; _run-parts.sh breaks out of the chain
#   other non-zero — logged but chain continues (per FR-015)

set -euo pipefail

DATA_DIR="${DATA_DIR:-$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}" 2>/dev/null || echo "$0")")/../../../..)}"
PEER="${HOST_NAME:-}"

# Required env vars — empty or unset → abort.
if [ -z "${HOST_NAME:-}" ]; then
    echo "[00-validate] abort: HOST_NAME is empty" >&2
    exit 254
fi
if [ -z "${PEER_NETLOC:-}" ]; then
    echo "[00-validate] abort: PEER_NETLOC is empty" >&2
    exit 254
fi
if [ -z "${PEER_CERT_FILE:-}" ] || [ ! -f "${PEER_CERT_FILE}" ]; then
    echo "[00-validate] abort: PEER_CERT_FILE is not set or path is missing: ${PEER_CERT_FILE:-<unset>}" >&2
    exit 254
fi
if [ -z "${PEER_NNCP_ID:-}" ]; then
    echo "[00-validate] abort: PEER_NNCP_ID is empty (peer cert is not Ed25519, or peer_extract failed)" >&2
    exit 254
fi
if [ -z "${OUR_CERT:-}" ] || [ -z "${OUR_KEY:-}" ]; then
    echo "[00-validate] abort: OUR_CERT and OUR_KEY are required by 50-bundle-push.sh" >&2
    exit 254
fi

# Don't process our own announcement back to ourselves.
if [ "$PEER" = "${OUR_CERT_BASENAME:-}" ] 2>/dev/null; then :; fi
if [ "$PEER_NETLOC" = "localhost:${MTLS_DAV_PORT:-8443}" ] || [ "$PEER_NETLOC" = "localhost:${MTLS_DAV_PORT_PARENT:-8443}" ]; then
    :  # placeholder, ignore
fi

echo "[00-validate] ok: peer=$PEER netloc=$PEER_NETLOC nncp-id=$PEER_NNCP_ID"
exit 0
