#!/bin/bash
# mtls-drop — PUT a local file to /drop/<cn>/<name>.
# shellcheck disable=SC2154  # _mtls_cn, _mtls_curl_status set by sourced _common-cname.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/_common-cname.sh"

SOURCE=""
NAME=""
CONTENT_TYPE=""
ETAG=""
IF_NONE_MATCH=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --source)       SOURCE="$2"; shift 2 ;;
        --name)         NAME="$2"; shift 2 ;;
        --content-type) CONTENT_TYPE="$2"; shift 2 ;;
        --etag)         ETAG="$2"; shift 2 ;;
        --if-none-match) IF_NONE_MATCH="1"; shift ;;
        *) _mtls_parse_args "$@"; break ;;
    esac
done

[ -n "$SOURCE" ] || { echo "error: --source is required" >&2; exit 2; }
[ -f "$SOURCE" ] || { echo "error: file not found: $SOURCE" >&2; exit 2; }
[ -n "$NAME" ] || NAME="$(basename -- "$SOURCE")"
[ -n "$CONTENT_TYPE" ] || CONTENT_TYPE="$(file -b --mime-type -- "$SOURCE" 2>/dev/null || echo application/octet-stream)"

trap _mtls_cleanup EXIT
_mtls_curl PUT "$(_mtls_url "$NAME")" \
    --header "Content-Type: $CONTENT_TYPE" \
    ${ETAG:+--header "If-Match: \"$ETAG\""} \
    ${IF_NONE_MATCH:+--header "If-None-Match: *"} \
    --data-binary "@$SOURCE"

case "$_mtls_curl_status" in
    201) echo "(201 created drop/$_mtls_cn/$NAME)" ;;
    204) echo "(204 overwritten drop/$_mtls_cn/$NAME)" ;;
    412) echo "(412 precondition failed)" ;;
    401) echo "(401 unauthorized)" >&2 ;;
    403) echo "(403 forbidden — cross-host?)" >&2 ;;
    *)   echo "($_mtls_curl_status unexpected)" >&2 ;;
esac
_mtls_exit_for_status "$_mtls_curl_status"
