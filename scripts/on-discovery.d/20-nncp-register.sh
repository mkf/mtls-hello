#!/usr/bin/env bash
# scripts/on-discovery.d/20-nncp-register.sh — insert or update the peer's
# neigh: entry in <data-dir>/nncp.hjson. The peer's NNCP keys come from
# env vars populated by scripts/on-discovery.d/_run-parts.sh via
# scripts/cgi-trust.sh\#peer_extract.
#
# Required env:
#   HOST_NAME          — peer display name; becomes the neighbor key
#   PEER_NNCP_ID       — base32-32 (BLAKE2b-256 of peer's signpub)
#   PEER_SIGNPUB       — base32-32 of peer's Ed25519 signpub
#   PEER_EXCHPUB       — base32-32 of peer's X25519 exchpub
#   PEER_NOISEPUB      — base32-32 (optional; empty if peer has no noise key)
#
# Idempotent: replaces the existing `neigh.<HOST_NAME>` block; leaves
# unrelated neigh: entries untouched.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DATA_DIR="${DATA_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
NNCP_HJSON="$DATA_DIR/nncp.hjson"

# Get helpers.
. "$DATA_DIR/scripts/cgi-lib.sh" 2>/dev/null || . "$PROJECT_ROOT/scripts/cgi-lib.sh"

PEER="${HOST_NAME:-}"
NNCP_ID="${PEER_NNCP_ID:-}"
SIGNPUB="${PEER_SIGNPUB:-}"
EXCHPUB="${PEER_EXCHPUB:-}"
NOISEPUB="${PEER_NOISEPUB:-}"

[ -n "$PEER" ]    || { echo "[20-nncp-register] abort: HOST_NAME empty" >&2; exit 254; }
[ -n "$NNCP_ID" ] || { echo "[20-nncp-register] abort: PEER_NNCP_ID empty (peer cert not Ed25519)" >&2; exit 254; }
[ -n "$SIGNPUB" ] || { echo "[20-nncp-register] abort: PEER_SIGNPUB empty" >&2; exit 254; }
[ -n "$EXCHPUB" ] || { echo "[20-nncp-register] abort: PEER_EXCHPUB empty" >&2; exit 254; }

[ -f "$NNCP_HJSON" ] || touch -- "$NNCP_HJSON"

# Hand off to the project's existing nncp-hjson helper (added in feature 025).
nncp_hjson_set_neigh "$NNCP_HJSON" "$PEER" "$NNCP_ID" "$EXCHPUB" "$SIGNPUB" "$NOISEPUB"
echo "[20-nncp-register] neigh:  $PEER  id=$NNCP_ID"
exit 0
