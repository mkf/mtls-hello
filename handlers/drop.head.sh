#!/bin/bash
# CGI handler: HEAD /drop/<name> → headers-only fetch.
# Returns 200 + ETag / Last-Modified / Content-Type / Content-Length for an
# existing file; 404 for missing; 400 / 403 / 401 / 412 for the same gate
# errors as drop.get.sh, but with no body and no Range processing.
set -euo pipefail

# shellcheck disable=SC1091
. "${MTLS_DATA_DIR}/scripts/cgi-common.sh"
# shellcheck disable=SC1091
. "${MTLS_DATA_DIR}/scripts/cgi-trust.sh"
# shellcheck disable=SC1091
. "${MTLS_DATA_DIR}/scripts/cgi-dropbox.sh"

if [ -z "${SSL_CLIENT_CERT:-}" ]; then
    echo "Status: 401 Unauthorized"
    echo "Content-Type: text/plain"
    echo "Content-Length: 0"
    echo ""
    exit 0
fi
if ! is_trusted; then
    echo "Status: 401 Unauthorized"
    echo "Content-Type: text/plain"
    echo "Content-Length: 0"
    echo ""
    exit 0
fi

cn="$(dropbox_caller_cn)" || { echo "Status: 400 Bad Request"; echo "Content-Length: 0"; echo ""; exit 0; }
rel="$(dropbox_validate_path "${PATH_INFO:-}"/)" \
    || { echo "Status: 400 Bad Request"; echo "Content-Length: 0"; echo ""; exit 0; }

if [ -z "$rel" ]; then
    # HEAD on the collection: we don't know a single ETag to emit; we just
    # confirm that the box exists. 200 with no headers beyond Content-Length
    # and a fixed Allow: is what most clients expect.
    box="$(dropbox_box_dir "$cn" 2>/dev/null || true)"
    if [ -z "$box" ] || [ ! -d "$box" ]; then
        echo "Status: 404 Not Found"
        echo "Content-Length: 0"
        echo ""
        exit 0
    fi
    echo "Status: 200 OK"
    echo "Content-Length: 0"
    echo "Allow: GET HEAD PUT DELETE OPTIONS PROPFIND MKCOL COPY MOVE"
    echo "DAV: 1, 2"
    echo ""
    exit 0
fi

target="$(dropbox_resolve "$cn" "$rel" 2>/dev/null || true)"
if [ -z "$target" ] || [ ! -e "$target" ]; then
    echo "Status: 404 Not Found"
    echo "Content-Length: 0"
    echo ""
    exit 0
fi
if [ ! -f "$target" ]; then
    # HEAD on a directory — advertise allowed methods but no body.
    echo "Status: 200 OK"
    echo "Content-Length: 0"
    echo "Content-Type: httpd/unix-directory"
    echo "Allow: GET HEAD PUT DELETE OPTIONS PROPFIND MKCOL COPY MOVE"
    echo "DAV: 1, 2"
    echo ""
    exit 0
fi

size="$(stat -c '%s' "$target")"
mtime_epoch="$(stat -c '%Y' "$target")"
lastmod="$(dropbox_http_date "$mtime_epoch")"
etag="$(dropbox_read_cached_etag "$target")"

mime="application/octet-stream"
meta="$(dropbox_read_drop_meta "$target" 2>/dev/null || true)"
mime="$(echo "$meta" | sed -n 's/^user\.mime=//p')"
[ -z "$mime" ] && mime="application/octet-stream"

# If-Modified-Since / If-None-Match: respond 304 with no body and the same
# validators as GET. RFC 7232 §4.1 says HEAD on a 304 must NOT include any
# representation metadata; we emit only the validators.
if [ -n "${HTTP_IF_MODIFIED_SINCE:-}" ] \
        && dropbox_compare_if_modified_since "${HTTP_IF_MODIFIED_SINCE:-}" "$mtime_epoch"; then
    echo "Status: 304 Not Modified"
    echo "ETag: \"$etag\""
    echo "Last-Modified: $lastmod"
    echo "Content-Length: 0"
    echo ""
    exit 0
fi
if [ -n "${HTTP_IF_NONE_MATCH:-}" ] && [ "${HTTP_IF_NONE_MATCH:-}" = "$etag" ]; then
    echo "Status: 304 Not Modified"
    echo "ETag: \"$etag\""
    echo "Last-Modified: $lastmod"
    echo "Content-Length: 0"
    echo ""
    exit 0
fi

echo "Status: 200 OK"
echo "ETag: \"$etag\""
echo "Last-Modified: $lastmod"
echo "Content-Type: $mime"
echo "Allow: GET HEAD PUT DELETE OPTIONS PROPFIND MKCOL COPY MOVE"
echo "DAV: 1, 2"
echo "Content-Length: $size"
echo ""
exit 0
