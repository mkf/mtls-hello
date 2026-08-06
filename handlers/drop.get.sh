#!/bin/bash
# CGI handler: GET /drop/<name> → fetch a file from the caller's drop-box.
# Also handles GET /drop (no name) as a collection listing (extends to T021).
# Supports Range (RFC 7233, single-range), conditional requests (ETag +
# Last-Modified + If-None-Match + If-Modified-Since), and HEAD behaviour
# is duplicated by drop.head.sh (separate file to keep this script
# stream-friendly).
set -euo pipefail

# shellcheck disable=SC1091
. "${MTLS_DATA_DIR}/scripts/cgi-common.sh"
# shellcheck disable=SC1091
. "${MTLS_DATA_DIR}/scripts/cgi-trust.sh"
# shellcheck disable=SC1091
. "${MTLS_DATA_DIR}/scripts/cgi-dropbox.sh"

if [ -z "${SSL_CLIENT_CERT:-}" ]; then
    cgi_error "401 Unauthorized" "No client certificate presented"
fi
if ! is_trusted; then
    cgi_error "401 Unauthorized" "Untrusted"
fi

cn="$(dropbox_caller_cn)" || cgi_error "400 Bad Request" "bad CN"

rel="$(dropbox_validate_path "${PATH_INFO:-}"/)" || cgi_error "400 Bad Request" "bad path"

# Empty path ("/drop" or "/drop/") -> collection listing; we treat GET on a
# collection as a simple plain-text listing (no RFC multistatus here for
# fetch; PROPFIND is the right verb for structured metadata per US2).
if [ -z "$rel" ]; then
    box="$(dropbox_box_dir "$cn")" || cgi_error "500 Internal Server Error" "no box"
    echo "Content-Type: text/plain; charset=\"utf-8\""
    echo ""
    # Use find -L or simple line-by-line iteration. Avoid using "rm" / "find
    # -delete"; here we just read names. Don't recurse — keep it shallow.
    while IFS= read -r -d '' entry; do
        # entry is "box/<rel>" — print the relative portion only.
        sub="${entry#"$box/"}"
        [ -z "$sub" ] && continue
        # Skip sidecar .meta files; they are not the user's drop items.
        case "$sub" in
            *.meta) continue ;;
        esac
        if [ -d "$entry" ]; then
            # Use stat for size (gives the directory's own size, which is
            # OS-specific; we report '-' for clarity).
            size="-"
        else
            size="$(stat -c '%s' "$entry")"
        fi
        meta="$(dropbox_read_drop_meta "$entry" 2>/dev/null || true)"
        ct="$(echo "$meta" | sed -n 's/^user\.mime=//p')"
        et="$(echo "$meta" | sed -n 's/^user\.etag=//p')"
        lm="$(echo "$meta" | sed -n 's/^user\.lastmod=//p')"
        [ -z "$ct" ] && ct="application/octet-stream"
        printf '%s\t%s\t%s\t%s\t%s\n' "$sub" "$size" "$ct" "${et:--}" "${lm:--}"
    done < <(find "$box" -mindepth 1 -maxdepth 1 -print0 -not -name '*.meta')
    exit 0
fi

target="$(dropbox_resolve "$cn" "$rel")" || cgi_error "403 Forbidden" "outside box"

if [ ! -e "$target" ]; then
    cgi_error "404 Not Found" "no such file"
fi
if [ -d "$target" ]; then
    # GET on a directory is allowed and is just the listing of that subtree.
    echo "Content-Type: text/plain; charset=\"utf-8\""
    echo ""
    while IFS= read -r -d '' entry; do
        sub="${entry#"$target/"}"
        [ -z "$sub" ] && continue
        case "$sub" in
            *.meta) continue ;;
        esac
        if [ -d "$entry" ]; then size="-"; else size="$(stat -c '%s' "$entry")"; fi
        meta="$(dropbox_read_drop_meta "$entry" 2>/dev/null || true)"
        ct="$(echo "$meta" | sed -n 's/^user\.mime=//p')"
        et="$(echo "$meta" | sed -n 's/^user\.etag=//p')"
        [ -z "$ct" ] && ct="application/octet-stream"
        printf '%s\t%s\t%s\t%s\n' "$sub" "$size" "$ct" "${et:--}"
    done < <(find "$target" -mindepth 1 -maxdepth 1 -print0 -not -name '*.meta')
    exit 0
fi

# GET on a single file — full conditional + range machinery.
size="$(stat -c '%s' "$target")"
mtime_epoch="$(stat -c '%Y' "$target")"
lastmod="$(dropbox_http_date "$mtime_epoch")"
etag="$(dropbox_read_cached_etag "$target")"

# Last-Modified-based 'not modified' check first — runs before ETag to keep
# semantics correct (RFC 7232: any-satisfied is "not modified").
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

# Content-Type provenance: stored mime, or fall back to a filename-extension
# lookup via Apache's mime.types if present, else application/octet-stream.
mime="application/octet-stream"
meta="$(dropbox_read_drop_meta "$target" 2>/dev/null || true)"
mime="$(echo "$meta" | sed -n 's/^user\.mime=//p')"
if [ -z "$mime" ]; then mime="application/octet-stream"; fi

# Content-Disposition: attachment; filename="<original>"
disp_name="$(echo "$meta" | sed -n 's/^user\.name=//p')"
[ -z "$disp_name" ] && disp_name="$(basename -- "$target")"

# Range handling (single-range only). Empty header = full response.
range_hdr="${HTTP_RANGE:-}"
range_out=""
if [ -n "$range_hdr" ]; then
    range_out="$(dropbox_parse_range "$range_hdr" "$size")" || {
        rc=$?
        if [ "$range_out" = "multi" ]; then
            cgi_error "501 Not Implemented" "multi-range not supported"
        fi
        cgi_error "416 Requested Range Not Satisfiable" "bad range"
    }
fi
start="${range_out%% *}"
end="${range_out#* }"
clen=$(( end - start + 1 ))

echo "Status: 200 OK"
echo "ETag: \"$etag\""
echo "Last-Modified: $lastmod"
echo "Content-Type: $mime"
echo "Content-Disposition: attachment; filename=\"$disp_name\""
if [ -n "$range_hdr" ] && [ "$range_out" = "out" ]; then
    cgi_error "416 Requested Range Not Satisfiable" "out of range"
fi
if [ -n "$range_hdr" ]; then
    echo "Content-Range: bytes $start-$end/$size"
fi
echo "Content-Length: $clen"
echo ""

# Stream the bytes: use dd to slice the file.
dd if="$target" bs=1 skip="$start" count="$clen" status=none
exit 0
