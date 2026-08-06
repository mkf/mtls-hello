#!/bin/bash
# mtls-props — PROPFIND Depth:0 on a single /drop/<cn>/<name>.
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
_mtls_curl PROPFIND "$(_mtls_url "$NAME")" \
    --header "Depth: 0" \
    --header "Content-Type: application/xml"

if [ "$_mtls_curl_status" != "207" ] && [ "$_mtls_curl_status" != "200" ]; then
    echo "($_mtls_curl_status)" >&2
    _mtls_exit_for_status "$_mtls_curl_status"
fi

# Extract property values from the multistatus XML.
extract() { sed -n "s/.*<$1>\([^<]*\)<\/$1>.*/\1/p" "$_mtls_body_file" 2>/dev/null || true; }
echo "resourcetype: $(extract 'D:resourcetype' || extract 'd:resourcetype' || echo unknown)"
echo "getcontentlength: $(extract 'D:getcontentlength' || extract 'd:getcontentlength' || echo -)"
echo "getcontenttype: $(extract 'D:getcontenttype' || extract 'd:getcontenttype' || echo -)"
echo "getlastmodified: $(extract 'D:getlastmodified' || extract 'd:getlastmodified' || echo -)"
echo "getetag: $(extract 'D:getetag' || extract 'd:getetag' || echo -)"
