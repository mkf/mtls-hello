#!/usr/bin/env bash
# scripts/on-discovery.d/10-trust-add.sh — adds (or replaces) the peer's
# mTLS certificate into our trust store at <data-dir>/hosts/<cn>.crt.
#
# Required env:
#   HOST_NAME       — peer CN
#   PEER_CERT_FILE  — path to the peer's mTLS cert (already captured by
#                     scripts/log-capture.sh during the Apache request
#                     that triggered discovery)
#
# This is the per-host-fingerprint-match anchor that Apache's
# `SSLVerifyClient optional_no_ca` consults.
#
# Idempotent: replaces the existing file rather than appends.

set -euo pipefail

DATA_DIR="${DATA_DIR:-$(dirname -- "${BASH_SOURCE[0]}")}/../../../..}"
TRUST_DIR="$DATA_DIR/hosts"
mkdir -p -- "$TRUST_DIR"

PEER="${HOST_NAME:-}"
CERT="${PEER_CERT_FILE:-}"

[ -n "$PEER" ] || { echo "[10-trust-add] abort: HOST_NAME empty" >&2; exit 254; }
[ -n "$CERT" ] || { echo "[10-trust-add] abort: PEER_CERT_FILE empty" >&2; exit 254; }
[ -f "$CERT" ] || { echo "[10-trust-add] abort: PEER_CERT_FILE=$CERT missing" >&2; exit 254; }

# Idempotent overwrite — anchored path, plain cp --. Per safety rule (G1): no
# `rm -f` / `rm -rf`.
cp -- "$CERT" "$TRUST_DIR/$PEER.crt"
chmod 0644 "$TRUST_DIR/$PEER.crt" || true

# Compute fingerprint for the log line and stderr records.
fp="$(openssl x509 -in "$TRUST_DIR/$PEER.crt" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2 | tr -d ':')" || fp="(unparsable)"
echo "[10-trust-add] trust store updated: $PEER.crt (fingerprint $fp)"
exit 0
