#!/usr/bin/env bash
# gen-certs.sh - generate Ed25519+X25519 identity material for mtls-hello
# AND emit a <data-dir>/nncp.hjson that doubles as the NNCP `self:` block.
#
# Why one script, three keys:
#   - The mTLS X.509 cert needs an Ed25519 signpub;
#   - The TLS handshake negotiates ECDHE_X25519 via the cipher list (no cert field);
#   - NNCP wants three raw base32 scalars: exchpub/exchprv (X25519), signpub/signprv
#     (Ed25519, signprv = seed||public per NNCP's ed25519.PrivateKeySize=64),
#     noisepub/noiseprv (X25519).
#
# Usage:
#   scripts/gen-certs.sh --cn <host> [-d <data-dir>] [--legacy-rsa-import <dir>]
#
# Notes:
#   * Idempotent: re-running rewrites the cert, key, and nncp.hjson in place.
#   * No `rm -rf`. We never delete anything that the project doesn't already track.
#   * Backed-up legacy RSA material (--legacy-rsa-import) is preserved under
#     <data-dir>/identity-legacy-<timestamp>/ and never overwritten.

set -euo pipefail

CN=""
DATA_DIR=""
LEGACY_DIR=""

while [ $# -gt 0 ]; do
    case "$1" in
        --cn) CN="$2"; shift 2 ;;
        -d|--data-dir) DATA_DIR="$2"; shift 2 ;;
        --legacy-rsa-import) LEGACY_DIR="$2"; shift 2 ;;
        -h|--help)
            cat <<USE
usage: gen-certs.sh --cn <host> [-d <data-dir>] [--legacy-rsa-import <dir>]

  --cn <host>          CN for the X.509 self-signed certificate.
  -d, --data-dir DIR   Where to write identity/, identity-legacy-<ts>, nncp.hjson
                       (default: \$HOME/.local/share/mtls-hello).
  --legacy-rsa-import DIR
                       Copy <dir>/<cn>.{crt,key} under
                       <data-dir>/identity-legacy-<timestamp>/ before writing new
                       Ed25519 material.
USE
            exit 0
            ;;
        *) echo "gen-certs.sh: unknown arg: $1" >&2; exit 2 ;;
    esac
done

[ -n "$CN" ] || { echo "gen-certs.sh: --cn <host> is required" >&2; exit 2; }
[ -n "$DATA_DIR" ] || DATA_DIR="${HOME}/.local/share/mtls-hello"

CN_FN="$(printf '%s' "$CN" | tr -c 'A-Za-z0-9._-' '_')"

command -v openssl >/dev/null || { echo "gen-certs.sh: openssl not on PATH" >&2; exit 1; }
command -v xxd >/dev/null || { echo "gen-certs.sh: xxd not on PATH (needed to read raw bytes)" >&2; exit 1; }
# BLAKE2b-256 32-byte digest for the NNCP id. Prefer the standalone `blake2b`
# binary when present; fall back to coreutils' `b2sum -l 32` on hosts
# (e.g. Tumbleweed-Slowroll) that don't ship `blake2b`. Both produce the
# exact same 32-byte BLAKE2b-256 digest per RFC 7693.
if command -v blake2b >/dev/null 2>&1; then
    blake2b_32() { blake2b -l 32; }
elif command -v b2sum >/dev/null 2>&1; then
    # b2sum's -l is in BITS (256 = 32 bytes); output is hex text, so we
    # cut the hash field and convert hex→raw to match standalone blake2b's
    # raw-byte output.
    blake2b_32() { b2sum -l 256 | cut -d' ' -f1 | xxd -r -p; }
else
    echo "gen-certs.sh: no BLAKE2b binary on PATH (need blake2b or b2sum)" >&2
    exit 1
fi

IDENT_DIR="$DATA_DIR/identity"
mkdir -p "$IDENT_DIR"

CRED_FILE="$IDENT_DIR/$CN_FN.crt"
KEY_FILE="$IDENT_DIR/$CN_FN.key"
NNCP_HJSON="$DATA_DIR/nncp.hjson"

# Honour the legacy-RSA-import path before overwriting anything.
if [ -n "$LEGACY_DIR" ] && [ -d "$LEGACY_DIR" ]; then
    if [ -f "$LEGACY_DIR/$CN_FN.crt" ] || [ -f "$LEGACY_DIR/$CN_FN.key" ]; then
        TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
        BACKUP="$DATA_DIR/identity-legacy-$TIMESTAMP"
        mkdir -p "$BACKUP"
        # Per safety rule (G1): anchored filenames only; no wildcards.
        [ -f "$LEGACY_DIR/$CN_FN.crt" ] && cp -- "$LEGACY_DIR/$CN_FN.crt" "$BACKUP/$CN_FN.crt"
        [ -f "$LEGACY_DIR/$CN_FN.key" ] && cp -- "$LEGACY_DIR/$CN_FN.key" "$BACKUP/$CN_FN.key"
        # Also copy whatever was already in the new path (the previous Ed25519 set, if any).
        [ -f "$CRED_FILE" ] && cp -- "$CRED_FILE" "$BACKUP/${CN_FN}.ed25519.crt"
        [ -f "$KEY_FILE" ] && cp -- "$KEY_FILE" "$BACKUP/${CN_FN}.ed25519.key"
        echo "gen-certs.sh: backed up legacy material to $BACKUP"
    fi
fi

# Generate three short-lived keypairs.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/gen-certs.XXXX")"
trap 'rm -- "$WORK"/ed_priv.pem "$WORK"/xchg_priv.pem "$WORK"/noise_priv.pem 2>/dev/null; rmdir -- "$WORK" 2>/dev/null || true' EXIT

openssl genpkey -algorithm ED25519 -out "$WORK/ed_priv.pem" 2>/dev/null
openssl genpkey -algorithm X25519  -out "$WORK/xchg_priv.pem" 2>/dev/null
openssl genpkey -algorithm X25519  -out "$WORK/noise_priv.pem" 2>/dev/null

# Extract raw 32-byte scalars/pubs.
#   Ed25519 PKCS#8 ends with the 32-byte seed; SPKI ends with the 32-byte pub.
#   We `tail -c 32` of the respective DER blobs and verify byte-count.
SEED_HEX="$(openssl pkey -in "$WORK/ed_priv.pem" -outform DER 2>/dev/null | tail -c 32 | xxd -p -c 256 | tr -d '\n')"
SIGN_PUB_HEX="$(openssl pkey -in "$WORK/ed_priv.pem" -pubout -outform DER 2>/dev/null | tail -c 32 | xxd -p -c 256 | tr -d '\n')"
XCHG_PRV_HEX="$(openssl pkey -in "$WORK/xchg_priv.pem" -outform DER 2>/dev/null | tail -c 32 | xxd -p -c 256 | tr -d '\n')"
XCHG_PUB_HEX="$(openssl pkey -in "$WORK/xchg_priv.pem" -pubout -outform DER 2>/dev/null | tail -c 32 | xxd -p -c 256 | tr -d '\n')"
NOISE_PRV_HEX="$(openssl pkey -in "$WORK/noise_priv.pem" -outform DER 2>/dev/null | tail -c 32 | xxd -p -c 256 | tr -d '\n')"
NOISE_PUB_HEX="$(openssl pkey -in "$WORK/noise_priv.pem" -pubout -outform DER 2>/dev/null | tail -c 32 | xxd -p -c 256 | tr -d '\n')"

STRICT_LEN=64
[ ${#SEED_HEX}      -eq $STRICT_LEN ] || { echo "gen-certs.sh: seed extraction failed (got ${#SEED_HEX} hex chars)" >&2; exit 1; }
[ ${#SIGN_PUB_HEX}  -eq $STRICT_LEN ] || { echo "gen-certs.sh: signpub extraction failed (got ${#SIGN_PUB_HEX} hex chars)" >&2; exit 1; }
[ ${#XCHG_PRV_HEX}   -eq $STRICT_LEN ] || { echo "gen-certs.sh: exchprv extraction failed (got ${#XCHG_PRV_HEX} hex chars)" >&2; exit 1; }
[ ${#XCHG_PUB_HEX}  -eq $STRICT_LEN ] || { echo "gen-certs.sh: exchpub extraction failed (got ${#XCHG_PUB_HEX} hex chars)" >&2; exit 1; }
[ ${#NOISE_PRV_HEX}  -eq $STRICT_LEN ] || { echo "gen-certs.sh: noiseprv extraction failed (got ${#NOISE_PRV_HEX} hex chars)" >&2; exit 1; }
[ ${#NOISE_PUB_HEX} -eq $STRICT_LEN ] || { echo "gen-certs.sh: noisepub extraction failed (got ${#NOISE_PUB_HEX} hex chars)" >&2; exit 1; }

# Compute NNCP id = BLAKE2b-256 of signpub (32-byte digest), via the `blake2b_32`
# helper resolved above (blake2b on CI, b2sum on Tumbleweed-Slowroll).
NNCP_ID="$(printf '%s' "$SIGN_PUB_HEX" | xxd -r -p | blake2b_32 | base32 -w 0)"

# Build the NNCP raw key block as base32-32 / base32-64 strings (RFC 4648 no padding).
hex_to_b32() { printf '%s' "$1" | xxd -r -p | base32 -w 0; }
SIGN_PUB_B32="$(hex_to_b32 "$SIGN_PUB_HEX")"
SIGN_PRV_B32="$(hex_to_b32 "${SEED_HEX}${SIGN_PUB_HEX}")"   # 64-byte NNCP form: seed||pub
XCHG_PUB_B32="$(hex_to_b32 "$XCHG_PUB_HEX")"
XCHG_PRV_B32="$(hex_to_b32 "$XCHG_PRV_HEX")"
NOISE_PUB_B32="$(hex_to_b32 "$NOISE_PUB_HEX")"
NOISE_PRV_B32="$(hex_to_b32 "$NOISE_PRV_HEX")"

# Step A) Generate the X.509 cert with Ed25519 signature.
# Self-signed, basic constraints absent (so it can sign both client and server),
# EKU=serverAuth+clientAuth per the existing feature 010 spec; CN=<host>.
openssl req -new -x509 \
    -key "$WORK/ed_priv.pem" \
    -days 3650 \
    -subj "/CN=$CN" \
    -addext "extendedKeyUsage=serverAuth,clientAuth" \
    -out "$CRED_FILE" 2>/dev/null

# Step B) Re-emit the Ed25519 private key as PKCS#8 PEM (modern stable form).
openssl pkcs8 -topk8 -nocrypt -in "$WORK/ed_priv.pem" -out "$KEY_FILE" 2>/dev/null
chmod 600 "$KEY_FILE"

# Step C) Write <data-dir>/nncp.hjson (atomic via tempfile + mv).
TMP_HJSON="$(mktemp "${NNCP_HJSON}.XXXX")"
{
    cat <<EOF
# mtls-hello + NNCP key material, generated by scripts/gen-certs.sh for CN=$CN.
# All values RFC 4648 base32 without padding, per NNCP's cfg.go.
self: {
    id:       "$NNCP_ID"
    exchpub:  "$XCHG_PUB_B32"
    exchprv:  "$XCHG_PRV_B32"
    signpub:  "$SIGN_PUB_B32"
    signprv:  "$SIGN_PRV_B32"
    noisepub: "$NOISE_PUB_B32"
    noiseprv: "$NOISE_PRV_B32"
}
neigh: {
}
areas: {
}
EOF
} > "$TMP_HJSON"
mv -- "$TMP_HJSON" "$NNCP_HJSON"

echo "gen-certs.sh: wrote $CRED_FILE (X.509 Ed25519)"
echo "gen-certs.sh: wrote $KEY_FILE (PKCS#8 Ed25519 privkey)"
echo "gen-certs.sh: wrote $NNCP_HJSON (NNCP self: block; NNCP id=$NNCP_ID)"
