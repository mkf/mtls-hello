#!/bin/bash
# mtls-head — HEAD request on /drop/<cn>/<name>.
# shellcheck disable=SC2154  # _mtls_cn, _mtls_curl_status set by sourced _common-cname.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/_common-cname.sh"

NAME=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --name) NAME="$2"; shift 2 ;;
        *) _mtls_parse_args "$@"; break ;;
    esac
done

[ -n "$NAME" ] || { echo "error: --name is required" >&2; exit 2; }

trap _mtls_cleanup EXIT
_mtls_curl HEAD "$(_mtls_url "$NAME")"

# Print interesting headers.
grep -iE '^(Status|ETag|Last-Modified|Content-Type|Content-Length|Allow|DAV):' "$_mtls_hdr_file" 2>/dev/null || true
echo "Status: $_mtls_curl_status"
_mtls_exit_for_status "$_mtls_curl_status"
