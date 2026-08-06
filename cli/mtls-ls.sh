#!/bin/bash
# mtls-ls — PROPFIND Depth:1 listing of /drop/<cn>/.
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

trap _mtls_cleanup EXIT
_mtls_curl PROPFIND "$(_mtls_url "${DIR:-}")" \
    --header "Depth: 1" \
    --header "Content-Type: application/xml"

if [ "$_mtls_curl_status" != "207" ] && [ "$_mtls_curl_status" != "200" ]; then
    echo "($_mtls_curl_status)" >&2
    _mtls_exit_for_status "$_mtls_curl_status"
fi

# Parse multistatus XML via xmllint if available, else grep.
if command -v xmllint >/dev/null 2>&1; then
    xmllint --xpath '//*[local-name()="response"]' "$_mtls_body_file" 2>/dev/null |
        sed -n 's/.*<[^>]*href>\([^<]*\)<\/[^>]*href>.*/\1/p' || true
else
    grep -oP '(?<=<D:href>)[^<]+' "$_mtls_body_file" 2>/dev/null ||
    grep -oP '(?<=<d:href>)[^<]+' "$_mtls_body_file" 2>/dev/null ||
    cat "$_mtls_body_file"
fi
