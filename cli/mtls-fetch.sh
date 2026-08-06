#!/bin/bash
# mtls-fetch — GET a file from /drop/<cn>/<name>.
# shellcheck disable=SC2154  # _mtls_cn, _mtls_curl_status set by sourced _common-cname.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/_common-cname.sh"

NAME=""
OUT=""
RANGE=""
IF_NONE_MATCH=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --name)          NAME="$2"; shift 2 ;;
        --out)           OUT="$2"; shift 2 ;;
        --range)         RANGE="$2"; shift 2 ;;
        --if-none-match) IF_NONE_MATCH="$2"; shift 2 ;;
        *) _mtls_parse_args "$@"; break ;;
    esac
done

[ -n "$NAME" ] || { echo "error: --name is required" >&2; exit 2; }
[ -n "$OUT" ] || OUT="$(basename -- "$NAME")"

trap _mtls_cleanup EXIT
_mtls_curl GET "$(_mtls_url "$NAME")" \
    ${RANGE:+--header "Range: bytes=$RANGE"} \
    ${IF_NONE_MATCH:+--header "If-None-Match: \"$IF_NONE_MATCH\""}

# Copy body to output.
cp -- "$_mtls_body_file" "$OUT"

case "$_mtls_curl_status" in
    200) echo "(200 ok $(wc -c < "$OUT") bytes → $OUT)" ;;
    206) echo "(206 partial → $OUT)" ;;
    304) echo "(304 not modified)" ;;
    404) echo "(404 not found)" >&2 ;;
    416) echo "(416 range not satisfiable)" >&2 ;;
    *)   echo "($_mtls_curl_status)" >&2 ;;
esac
_mtls_exit_for_status "$_mtls_curl_status"
