#!/bin/bash
# mtls-mkcol — MKCOL a directory at /drop/<cn>/<dir>.
# shellcheck disable=SC2154  # _mtls_cn, _mtls_curl_status set by sourced _common-cname.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/_common-cname.sh"

DIR=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --dir) DIR="$2"; shift 2 ;;
        *) _mtls_parse_args "$@"; break ;;
    esac
done

[ -n "$DIR" ] || { echo "error: --dir is required" >&2; exit 2; }

trap _mtls_cleanup EXIT
_mtls_curl MKCOL "$(_mtls_url "$DIR")"

case "$_mtls_curl_status" in
    201) echo "(201 created drop/$_mtls_cn/$DIR)" ;;
    405) echo "(405 method not allowed — path exists)" ;;
    409) echo "(409 conflict — parent missing)" ;;
    *)   echo "($_mtls_curl_status)" >&2 ;;
esac
_mtls_exit_for_status "$_mtls_curl_status"
