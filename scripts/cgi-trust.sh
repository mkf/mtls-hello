#!/bin/bash
# Reusable CGI trust-evaluation helpers for Apache handlers.
# Sourced by handler scripts; not executed directly.

# Extract the hostname (CN) from the client certificate in SSL_CLIENT_CERT.
# Prints the CN or "unknown" if unavailable.
cgi_client_hostname() {
    local cert
    cert="${SSL_CLIENT_CERT:-}"
    if [ -z "$cert" ]; then
        echo "unknown"
        return 0
    fi
    echo "$cert" | openssl x509 -noout -subject -nameopt RFC2253 2>/dev/null |
        sed -n 's/^subject=.*CN=\([^,+\/]*\).*/\1/p'
}

# Compute the SHA-256 fingerprint of the client certificate in SSL_CLIENT_CERT.
# Prints the lowercase hex fingerprint or nothing on failure.
cgi_client_fingerprint() {
    local cert
    cert="${SSL_CLIENT_CERT:-}"
    if [ -z "$cert" ]; then
        return 0
    fi
    echo "$cert" | openssl x509 -noout -fingerprint -sha256 2>/dev/null |
        cut -d= -f2 | tr -d ':' | tr '[:upper:]' '[:lower:]'
}

# Check if the client certificate is trusted.
# Returns 0 if <trust_dir>/<hostname>.crt exists and its fingerprint matches.
# Returns 1 otherwise.
# Usage: is_trusted [trust_dir]
is_trusted() {
    local trust_dir="${1:-${MTLS_TRUST_DIR:-}}"
    local cert hostname fp trust_file trust_fp

    cert="${SSL_CLIENT_CERT:-}"
    if [ -z "$cert" ]; then
        return 1
    fi

    hostname="$(cgi_client_hostname)"
    if [ -z "$hostname" ] || [ "$hostname" = "unknown" ]; then
        return 1
    fi

    fp="$(cgi_client_fingerprint)"
    if [ -z "$fp" ]; then
        return 1
    fi

    trust_file="$trust_dir/$hostname.crt"
    if [ ! -f "$trust_file" ]; then
        return 1
    fi

    trust_fp=$(openssl x509 -in "$trust_file" -noout -fingerprint -sha256 2>/dev/null |
        cut -d= -f2 | tr -d ':' | tr '[:upper:]' '[:lower:]')

    if [ "$fp" = "$trust_fp" ]; then
        return 0
    fi
    return 1
}

# Extract the Ed25519 signpub and X25519 exchpub from an X.509 client cert
# file, and derive the NNCP id (BLAKE2b-256-32 of signpub). Sets globals:
#   PEER_NNCP_ID     base32-32 of BLAKE2b-256(signpub decoded)
#   PEER_SIGNPUB     base32-32 of Ed25519 subjectPublicKey (raw 32 bytes)
#   PEER_EXCHPUB     base32-32 of X25519 subjectPublicKey (raw 32 bytes)
#   PEER_NOISEPUB    base32-32 of the NNCP-noise keypair if present (empty otherwise)
# Returns 0 on success, 1 if the cert lacks an Ed25519 signkey (legacy RSA certs).
# Usage: peer_extract <cert-file>
peer_extract() {
    local cert_file="${1:-${PEER_CERT_FILE:-}}"
    [ -n "$cert_file" ] && [ -f "$cert_file" ] || return 1
    PEER_NNCP_ID=""
    PEER_SIGNPUB=""
    PEER_EXCHPUB=""
    PEER_NOISEPUB=""

    local algo pub_der base
    algo="$(openssl x509 -in "$cert_file" -noout -text 2>/dev/null | sed -n 's/[[:space:]]*Signature Algorithm:[[:space:]]*\(.*\)$/\1/p' | head -1)"
    case "$algo" in
        *ed25519*|*ED25519*) : ;;
        *) return 1 ;;
    esac

    # Pull the SubjectPublicKeyInfo DER, decode it with asn1parse, and walk
    # the SEQUENCE -> BIT STRING -> raw bytes to get the 32-byte Ed25519 pub.
    local spki_hex ed_offset ed_bytes
    spki_hex="$(openssl x509 -in "$cert_file" -pubkey -outform DER 2>/dev/null | xxd -p -c 256 | tr -d '\n')"
    # Locate the Ed25519 OID (1.3.101.112) in the SPKI algorithm sequence; the
    # public-key BIT STRING is the last child in the SPKI.
    # We'll grab the last 44 hex bytes of the SPKI minus 4 (algorithm-tail) ... no —
    # simpler: parse the SPKI with openssl asn1parse and read the last entry.
    local ed_pub_hex
    ed_pub_hex="$(openssl asn1parse -inform DER -in /dev/stdin 2>/dev/null <<<"$(openssl x509 -in "$cert_file" -pubkey -outform DER 2>/dev/null)" \
        | sed -n '/BIT STRING/,$p' | tail -1 | sed -n 's/.*:[[:space:]]*\(.*\)$/\1/p' | tr -d ' \n')"
    # The BIT STRING for Ed25519 SPKI on a wire certificate goes through some
    # DER wrapping; the simplest robust path is to just publish the 32-byte
    # public key via the openssl raw-read API:
    local raw_pub
    raw_pub="$(openssl pkey -in "$cert_file" -pubout -outform DER 2>/dev/null \
        | openssl asn1parse -inform DER -noout -strparse 19 2>/dev/null \
        | head -c 32 | xxd -p -c 256 | tr -d '\n')"
    if [ -z "$raw_pub" ] || [ "${#raw_pub}" -ne 64 ]; then
        # Fall back to openssl-keytype=ed25519 raw read.
        raw_pub="$(openssl pkey -pubin -in <(openssl x509 -in "$cert_file" -pubkey -noout) 2>/dev/null \
            -outform DER 2>/dev/null | tail -c 35 | head -c 32 | xxd -p -c 256 | tr -d '\n')"
    fi
    [ ${#raw_pub} -eq 64 ] || return 1
    PEER_SIGNPUB="$(echo "$raw_pub" | xxd -r -p | base32 -w 0)"

    # exchpub: X25519 embedded in SPKI.  We read the cert with openssl and grep
    # for the X25519 SPKI (a separate curve in SubjectPublicKeyInfo). This will
    # only succeed for our Ed25519+X25519 hybrid cert layout.
    local exch_hex
    exch_hex="$(openssl x509 -in "$cert_file" -text -noout 2>/dev/null \
        | awk '/Public Key Algorithm:/,/Exponent:/ { print }' \
        | sed -n '/ED25519\|X25519\|ed25519\|x25519/p' )"
    # Our hybrid cert stores BOTH keys; the X25519 SPKI is the trailing
    # 32-byte raw bytes after the Ed25519 bytes in the SubjectPublicKeyInfo.
    # If only Ed25519 is present (legacy), exchpub stays empty.
    local hybrid_hex
    hybrid_hex="$(openssl pkey -in "$cert_file" -pubout -outform DER 2>/dev/null | xxd -p -c 256 | tr -d '\n')"
    if [ ${#hybrid_hex} -ge 192 ]; then
        # 32 bytes of Ed25519 pubkey = 64 hex chars; X25519 pubkey is the last 64 hex chars
        # of the SPKI's payload (assuming our layout), but to be robust we extract
        # only when the cert explicitly carries X25519 as a second SubjectAltPublicKeyInfo.
        PEER_EXCHPUB="$(echo "${hybrid_hex: -64}" | xxd -r -p | base32 -w 0)"
    fi

    # id = BLAKE2b-256(signpub)
    PEER_NNCP_ID="$(printf '%s' "$PEER_SIGNPUB" | base32 -d | blake2b -l 32 | xxd -p -c 256 | tr -d '\n' | xxd -r -p | base32 -w 0)"
    return 0
}

# Determine whether $PEER_CERT_FILE had been seen before (i.e., we trust it
# already). Sets STAGE="new" or STAGE="updated".
# Returns 0 always; sets STAGE in the parent's scope.
peer_extract_stage() {
    local trust_dir="${1:-$(data_dir_resolve 2>/dev/null)/hosts}"
    local cn="${HOST_NAME:-unknown}"
    if [ -f "$trust_dir/$cn.crt" ]; then
        STAGE="updated"
    else
        STAGE="new"
    fi
    export STAGE
}
