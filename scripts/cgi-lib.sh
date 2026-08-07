#!/bin/bash
# cgi-lib.sh — Unified CGI and trust-evaluation library for Apache handlers
# and on-discovery.d scripts.
#
# Merged from cgi-common.sh + cgi-trust.sh (feature 026). All handlers source
# this single file instead of two. Not executed directly; sourced by consumers.
#
# Functions:
#   CGI utilities:   cgi_parse_query, cgi_header, cgi_error, cgi_require_trusted
#   Trust:           cgi_client_hostname, cgi_client_fingerprint, is_trusted
#   Cert extraction: extract_cn (from file), extract_cn_pem (from stdin)
#   NNCP peer keys:  peer_extract, peer_extract_stage
#   Path resolution: data_dir_resolve
#   NNCP config:     nncp_hjson_set_neigh

# ─── CGI Utilities ───────────────────────────────────────────────────────────

# Parse QUERY_STRING into QUERY_<KEY> variables (uppercase).
cgi_parse_query() {
    local qs="${QUERY_STRING:-}"
    local IFS='&'
    local pair key val upper
    for pair in $qs; do
        key="${pair%%=*}"
        val="${pair#*=}"
        val="${val//+/ }"
        val=$(printf '%b' "${val//%/\\x}")
        upper=$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]' | tr -c '[:alnum:]' '_')
        [ -n "$upper" ] && eval "QUERY_${upper}=\$val"
    done
}

# Emit a CGI response header and blank line.
# Usage: cgi_header [content-type]
cgi_header() {
    echo "Content-Type: ${1:-text/plain}"
    echo ""
}

# Emit a CGI error response with a status code.
# Usage: cgi_error <status_code> <message>
cgi_error() {
    echo "Status: $1"
    echo "Content-Type: text/plain"
    echo ""
    echo "$2"
    exit 0
}

# Require a trusted client certificate. Combines the SSL_CLIENT_CERT presence
# check and is_trusted() into a single call. Emits 401 and exits on failure.
# Usage: cgi_require_trusted
cgi_require_trusted() {
    local cert="${SSL_CLIENT_CERT:-}"
    if [ -z "$cert" ]; then
        cgi_error "401 Unauthorized" "No client certificate presented"
    fi
    if ! is_trusted; then
        cgi_error "401 Unauthorized" "Untrusted"
    fi
}

# ─── Trust Evaluation ────────────────────────────────────────────────────────

# Extract the hostname (CN) from the client certificate in SSL_CLIENT_CERT.
cgi_client_hostname() {
    local cert="${SSL_CLIENT_CERT:-}"
    if [ -z "$cert" ]; then
        echo "unknown"
        return 0
    fi
    extract_cn_pem <<<"$cert"
}

# Compute the SHA-256 fingerprint of the client certificate in SSL_CLIENT_CERT.
cgi_client_fingerprint() {
    local cert="${SSL_CLIENT_CERT:-}"
    if [ -z "$cert" ]; then
        return 0
    fi
    echo "$cert" | openssl x509 -noout -fingerprint -sha256 2>/dev/null |
        cut -d= -f2 | tr -d ':' | tr '[:upper:]' '[:lower:]'
}

# Check if the client certificate is trusted.
# Returns 0 if <trust_dir>/<hostname>.crt exists and fingerprint matches.
# Usage: is_trusted [trust_dir]
is_trusted() {
    local trust_dir="${1:-${MTLS_TRUST_DIR:-}}"
    local cert hostname fp trust_file trust_fp

    cert="${SSL_CLIENT_CERT:-}"
    [ -n "$cert" ] || return 1

    hostname="$(cgi_client_hostname)"
    [ -n "$hostname" ] && [ "$hostname" != "unknown" ] || return 1

    fp="$(cgi_client_fingerprint)"
    [ -n "$fp" ] || return 1

    trust_file="$trust_dir/$hostname.crt"
    [ -f "$trust_file" ] || return 1

    trust_fp=$(openssl x509 -in "$trust_file" -noout -fingerprint -sha256 2>/dev/null |
        cut -d= -f2 | tr -d ':' | tr '[:upper:]' '[:lower:]')

    [ "$fp" = "$trust_fp" ]
}

# ─── Certificate CN Extraction ───────────────────────────────────────────────

# Extract the CN from an X.509 certificate FILE.
# Uses RFC2253 nameopt (the most robust DN ordering).
# Usage: extract_cn <cert-file>
extract_cn() {
    local cert_file="$1"
    openssl x509 -in "$cert_file" -noout -subject -nameopt RFC2253 2>/dev/null |
        sed -n 's/^subject=.*CN=\([^,+\/]*\).*/\1/p'
}

# Extract the CN from a PEM certificate on STDIN.
# Usage: some_pem_producer | extract_cn_pem
extract_cn_pem() {
    openssl x509 -noout -subject -nameopt RFC2253 2>/dev/null |
        sed -n 's/^subject=.*CN=\([^,+\/]*\).*/\1/p'
}

# ─── Peer NNCP Key Extraction ────────────────────────────────────────────────

# Extract Ed25519 signpub and X25519 exchpub from an X.509 cert file, derive
# the NNCP id (BLAKE2b-256 of signpub). Sets globals:
#   PEER_NNCP_ID, PEER_SIGNPUB, PEER_EXCHPUB, PEER_NOISEPUB
# Returns 1 if cert lacks Ed25519 key (legacy RSA).
# Usage: peer_extract <cert-file>
# shellcheck disable=SC2034  # PEER_* globals are set for callers
peer_extract() {
    local cert_file="${1:-${PEER_CERT_FILE:-}}"
    [ -n "$cert_file" ] && [ -f "$cert_file" ] || return 1
    PEER_NNCP_ID=""
    PEER_SIGNPUB=""
    PEER_EXCHPUB=""
    PEER_NOISEPUB=""

    local algo
    algo="$(openssl x509 -in "$cert_file" -noout -text 2>/dev/null | sed -n 's/[[:space:]]*Signature Algorithm:[[:space:]]*\(.*\)$/\1/p' | head -1)"
    case "$algo" in
        *ed25519*|*ED25519*) : ;;
        *) return 1 ;;
    esac

    # shellcheck disable=SC2034  # spki_hex used for diagnostic; ed_pub_hex is fallback path
    local spki_hex
    spki_hex="$(openssl x509 -in "$cert_file" -pubkey -outform DER 2>/dev/null | xxd -p -c 256 | tr -d '\n')"
    local raw_pub
    raw_pub="$(openssl pkey -in "$cert_file" -pubout -outform DER 2>/dev/null \
        | openssl asn1parse -inform DER -noout -strparse 19 2>/dev/null \
        | head -c 32 | xxd -p -c 256 | tr -d '\n')"
    if [ -z "$raw_pub" ] || [ "${#raw_pub}" -ne 64 ]; then
        # shellcheck disable=SC2261
        raw_pub="$(openssl pkey -pubin -in <(openssl x509 -in "$cert_file" -pubkey -noout) 2>/dev/null \
            -outform DER 2>/dev/null | tail -c 35 | head -c 32 | xxd -p -c 256 | tr -d '\n')"
    fi
    [ ${#raw_pub} -eq 64 ] || return 1
    PEER_SIGNPUB="$(echo "$raw_pub" | xxd -r -p | base32 -w 0)"

    local hybrid_hex
    hybrid_hex="$(openssl pkey -in "$cert_file" -pubout -outform DER 2>/dev/null | xxd -p -c 256 | tr -d '\n')"
    if [ ${#hybrid_hex} -ge 192 ]; then
        PEER_EXCHPUB="$(echo "${hybrid_hex: -64}" | xxd -r -p | base32 -w 0)"
    fi

    PEER_NNCP_ID="$(printf '%s' "$PEER_SIGNPUB" | base32 -d | blake2b -l 32 | xxd -p -c 256 | tr -d '\n' | xxd -r -p | base32 -w 0)"
    return 0
}

# Determine whether PEER_CERT_FILE had been seen before. Sets STAGE="new" or "updated".
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

# ─── Path Resolution ─────────────────────────────────────────────────────────

# Resolve <data-dir> from env (MTLS_DATA_DIR set by Apache SetEnv), with
# fallbacks for unit-test invocations.
data_dir_resolve() {
    local d="${MTLS_DATA_DIR:-}"
    if [ -n "$d" ] && [ -d "$d" ]; then
        echo "$d"
        return 0
    fi
    d="${DATA_DIR:-}"
    if [ -n "$d" ] && [ -d "$d" ]; then
        echo "$d"
        return 0
    fi
    echo "${HOME}/.local/share/mtls-hello"
}

# ─── NNCP Config ─────────────────────────────────────────────────────────────

# Atomically merge a peer entry into <data-dir>/nncp.hjson's `neigh:` map.
# Usage: nncp_hjson_set_neigh <hjson-path> <peer-name> <id> <exchpub> <signpub> [noisepub]
nncp_hjson_set_neigh() {
    local hjson="$1" peer_name="$2" peer_id="$3" exchpub="$4" signpub="$5"
    local noisepub="${6:-}"
    local tmp
    tmp="$(mktemp "${hjson}.XXXX")"
    if [ ! -f "$hjson" ]; then
        {
            echo "self: {"
            echo "}"
            echo "neigh: {"
            [ -n "$noisepub" ] && np_field=", \"noisepub\": \"$noisepub\""
            echo "  \"$peer_name\": { \"id\": \"$peer_id\", \"exchpub\": \"$exchpub\", \"signpub\": \"$signpub\"$np_field }"
            echo "}"
        } > "$tmp"
        mv -- "$tmp" "$hjson"
        return 0
    fi
    awk -v peer="$peer_name" -v id="$peer_id" -v exch="$exchpub" \
        -v sign="$signpub" -v noise="$noisepub" '
        BEGIN { in_neigh = 0; wrote_peer = 0 }
        /^neigh:[[:space:]]*\{/ { print; in_neigh = 1; next }
        in_neigh == 1 && /^}/ {
            if (wrote_peer == 0) {
                printf("  \"%s\": { \"id\": \"%s\", \"exchpub\": \"%s\", \"signpub\": \"%s\"", peer, id, exch, sign)
                if (noise != "") printf(", \"noisepub\": \"%s\"", noise)
                print " }"
                wrote_peer = 1
            }
            print; in_neigh = 0
            next
        }
        in_neigh == 1 {
            line = $0
            if (line ~ "^[[:space:]]*\"" peer "\":[[:space:]]*\{") {
                nopen = gsub(/\{/, "&", line)
                nclose = gsub(/\}/, "&", line)
                depth = nopen - nclose
                while (depth > 0 && (getline line) > 0) {
                    nopen = gsub(/\{/, "&", line)
                    nclose = gsub(/\}/, "&", line)
                    depth += nopen - nclose
                }
                printf("  \"%s\": { \"id\": \"%s\", \"exchpub\": \"%s\", \"signpub\": \"%s\"", peer, id, exch, sign)
                if (noise != "") printf(", \"noisepub\": \"%s\"", noise)
                print " }"
                wrote_peer = 1
            } else {
                print
            }
            next
        }
        {
            wrote_neigh = 0
            print
        }
        END {
        }
    ' "$hjson" > "$tmp"
    if ! grep -q '^neigh:' "$tmp"; then
        {
            echo "" >> "$tmp"
            echo "neigh: {" >> "$tmp"
            [ -n "$noisepub" ] && np_field=", \"noisepub\": \"$noisepub\""
            echo "  \"$peer_name\": { \"id\": \"$peer_id\", \"exchpub\": \"$exchpub\", \"signpub\": \"$signpub\"$np_field }" >> "$tmp"
            echo "}" >> "$tmp"
        }
    fi
    mv -- "$tmp" "$hjson"
}
