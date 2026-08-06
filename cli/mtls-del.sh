#!/bin/bash
# mtls-del — DELETE a file or empty directory from /drop/<cn>/<name>.
# shellcheck disable=SC2154  # _mtls_cn, _mtls_curl_status set by sourced _common-cname.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/_common-cname.sh"

NAME=""
ETAG=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --name) NAME="$2"; shift 2 ;;
        --etag) ETAG="$2"; shift 2 ;;
        *) _mtls_parse_args "$@"; break ;;
    esac
done

[ -n "$NAME" ] || { echo "error: --name is required" >&2; exit 2; }

trap _mtls_cleanup EXIT
_mtls_curl DELETE "$(_mtls_url "$NAME")" \
    ${ETAG:+--header "If-Match: \"$ETAG\""}

case "$_mtls_curl_status" in
    204) echo "(204 deleted $NAME)" ;;
    404) echo "(404 not found)" ;;
    409) echo "(409 conflict — directory not empty)" ;;
    412) echo "(412 precondition failed)" ;;
    *)   echo "($_mtls_curl_status)" >&2 ;;
esac
_mtls_exit_for_status "$_mtls_curl_status"
