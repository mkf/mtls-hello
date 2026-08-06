#!/bin/bash
# mtls-cp — COPY an item within /drop/<cn>/.
# shellcheck disable=SC2154  # _mtls_cn, _mtls_curl_status set by sourced _common-cname.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/_common-cname.sh"

SRC=""
DST=""
OVERWRITE=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --source)    SRC="$2"; shift 2 ;;
        --dest)      DST="$2"; shift 2 ;;
        --overwrite) OVERWRITE="1"; shift ;;
        *) _mtls_parse_args "$@"; break ;;
    esac
done

[ -n "$SRC" ] || { echo "error: --source is required" >&2; exit 2; }
[ -n "$DST" ] || { echo "error: --dest is required" >&2; exit 2; }

trap _mtls_cleanup EXIT
_mtls_curl COPY "$(_mtls_url "$SRC")" \
    --header "Destination: $MTLS_SERVER/drop/$_mtls_cn/$DST" \
    ${OVERWRITE:+--header "Overwrite: T"}

case "$_mtls_curl_status" in
    201) echo "(201 copied $SRC -> $DST)" ;;
    204) echo "(204 overwritten $DST)" ;;
    412) echo "(412 precondition failed — destination exists)" ;;
    *)   echo "($_mtls_curl_status)" >&2 ;;
esac
_mtls_exit_for_status "$_mtls_curl_status"
