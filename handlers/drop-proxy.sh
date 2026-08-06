#!/bin/bash
# CGI handler: /drop/* trust-gate reverse-proxy.
#
# Receives all HTTP methods at /drop/<cn>/<rest>, validates the mTLS
# client cert fingerprint against <trust_dir>/<cn>.crt (reusing
# cgi-trust.sh is_trusted()), enforces that the URL's first segment
# matches the verified CN, then forwards the request to the loopback
# mod_dav VH at http://127.0.0.1:8444/drop/<cn>/<rest>.
#
# This is the ONLY piece of custom request-handling code; mod_dav on
# the loopback VH does all the actual file I/O (PUT/GET/DELETE/MKCOL/
# COPY/MOVE/PROPFIND/OPTIONS/HEAD/Range/ETag/conditional).
set -euo pipefail

# shellcheck disable=SC1091
. "${MTLS_DATA_DIR}/scripts/cgi-common.sh"
# shellcheck disable=SC1091
. "${MTLS_DATA_DIR}/scripts/cgi-trust.sh"

# --- trust gate -------------------------------------------------------

cert="${SSL_CLIENT_CERT:-}"
if [ -z "$cert" ]; then
    cgi_error "401 Unauthorized" "No client certificate presented"
fi
if ! is_trusted; then
    cgi_error "401 Unauthorized" "Untrusted"
fi

# --- CN / URL-prefix enforcement --------------------------------------

cn="$(cgi_client_hostname)"
if [ -z "$cn" ] || [ "$cn" = "unknown" ]; then
    cgi_error "400 Bad Request" "Could not extract CN from client certificate"
fi

# PATH_INFO is set by ScriptAlias to everything after the script name.
# For /drop/alice/notes.txt, PATH_INFO = /alice/notes.txt
path="${PATH_INFO#/}"          # "alice/notes.txt"
url_cn="${path%%/*}"           # "alice" (first segment)

if [ -z "$url_cn" ]; then
    cgi_error "400 Bad Request" "No hostname segment in /drop URL"
fi
if [ "$url_cn" != "$cn" ]; then
    # Cross-host access: trusted but wrong prefix.
    echo "Status: 403 Forbidden"
    echo "Content-Type: text/plain"
    echo ""
    echo "cross-host access denied"
    exit 0
fi

# --- forward to loopback mod_dav VH ----------------------------------

BACKEND_HOST="127.0.0.1"
BACKEND_PORT="${MTLS_DAV_PORT:-8444}"
BACKEND="http://${BACKEND_HOST}:${BACKEND_PORT}/drop/${path}"

method="${REQUEST_METHOD:-GET}"

# Collect headers to pass through (CGI gives them as HTTP_<NAME> with
# dashes→underscores, uppercase).
pass_headers=()
for h_name in Content-Type Content-Length Range Depth Destination Overwrite \
              If-Match If-None-Match If-Modified-Since If-Unmodified-Since; do
    h_var="HTTP_$(echo "$h_name" | tr '[:lower:]-' '[:upper:]_')"
    h_val="${!h_var:-}"
    if [ -n "$h_val" ]; then
        pass_headers+=(--header "${h_name}: ${h_val}")
    fi
done

# Read request body into a temp file (for methods that carry one).
body_tmp=""
case "$method" in
    PUT|POST|MKCOL|PROPFIND|LOCK)
        body_tmp="$(mktemp)"
        cat > "$body_tmp"
        ;;
esac

# Prepare temp files for the curl response.
hdr_tmp="$(mktemp)"
out_tmp="$(mktemp)"

# Build and execute curl.
curl_cmd=(curl -sS --max-time 300
    -X "$method"
    -D "$hdr_tmp"
    -o "$out_tmp"
    -w '%{http_code}'
    "${pass_headers[@]}"
)
if [ -n "$body_tmp" ]; then
    curl_cmd+=(--data-binary "@${body_tmp}")
fi
curl_cmd+=("$BACKEND")

# Execute; capture status code on stdout.
status_code="$("${curl_cmd[@]}" 2>/dev/null)" || {
    # curl failed (backend unreachable, etc.)
    cgi_error "502 Bad Gateway" "Backend mod_dav unreachable"
}

# --- relay response ---------------------------------------------------

# Parse the status line from the dumped headers.
# Apache dumps headers like:
#   HTTP/1.1 201 Created\r\n
#   Content-Type: text/plain\r\n
#   ...
# Parse status from dumped headers — we use _mtls_curl_status from
# curl's -w instead, so we skip the HTTP status line in the dump.
# Emit our own Status: header for CGI.
echo "Status: ${status_code}"

# Pass through response headers (skip the first HTTP/ status line and
# any Transfer-Encoding / Content-Length which CGI/Apache will recompute).
seen_ct=0
while IFS= read -r line; do
    # Skip blank lines and the HTTP/ status line.
    [ -z "$line" ] && continue
    case "$line" in
        HTTP/*) continue ;;
        Content-Length:*) continue ;;      # Apache recomputes
        Transfer-Encoding:*) continue ;;   # Apache recomputes
        Connection:*) continue ;;          # hop-by-hop
    esac
    # Print the header as-is (strip trailing \r if present).
    line="${line%$'\r'}"
    echo "$line"
    case "$line" in
        Content-Type:*) seen_ct=1 ;;
    esac
done < "$hdr_tmp"

# Ensure Content-Type is present.
if [ "$seen_ct" -eq 0 ]; then
    echo "Content-Type: application/octet-stream"
fi
echo ""

# Stream the response body.
cat "$out_tmp"

# --- cleanup ----------------------------------------------------------

rm -f -- "$hdr_tmp" "$out_tmp" 2>/dev/null || true
if [ -n "$body_tmp" ]; then
    rm -f -- "$body_tmp" 2>/dev/null || true
fi
exit 0
