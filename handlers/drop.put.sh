#!/bin/bash
# CGI handler: PUT /drop/<name> → store a file in the caller's drop-box.
# Requires a trusted client certificate. Uses SSL_CLIENT_S_DN_CN to pick the
# caller's box; the same CN must already be in the trust gate (which has
# the SSL_CLIENT_CERT fingerprint matched against <trust_dir>/<cn>.crt).
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

# Validate the requested name (from PATH_INFO; the rewrite preserves it).
rel="$(dropbox_validate_path "${PATH_INFO:-}"/)" || cgi_error "400 Bad Request" "bad path"

# Surface empty-target PUT — treat as "drop the box itself" (no-op without
# a SUPPORTED semantics; we reject so callers don't think they made a
# directory).
if [ -z "$rel" ]; then
    cgi_error "400 Bad Request" "PUT /drop without a name is not supported"
fi

target="$(dropbox_resolve "$cn" "$rel")" || cgi_error "403 Forbidden" "outside box"

# Conditional request handling (FR-010).
#
# Apache forwards relevant request headers as $HTTP_IF_MATCH /
# $HTTP_IF_NONE_MATCH / $HTTP_IF_UNMODIFIED_SINCE: with each '-' replaced
# by '_'. We delegate parsing to the helpers, which are RFC-tolerant.
et_in="$(dropbox_parse_if_match "${HTTP_IF_MATCH:-}")"
none_match="${HTTP_IF_NONE_MATCH:-}"

existed=0
if [ -e "$target" ]; then
    existed=1
    if [ -n "$et_in" ] && [ "$et_in" != "*" ]; then
        # Must match the current ETag.
        cur_etag="$(dropbox_read_cached_etag "$target")"
        if [ "$et_in" != "$cur_etag" ]; then
            cgi_error "412 Precondition Failed" "If-Match did not match"
        fi
    elif [ "$et_in" = "*" ]; then
        # "*" means "must exist" — satisfied by being here.
        :
    fi
    if [ "$none_match" = "*" ]; then
        cgi_error "412 Precondition Failed" "If-None-Match: * refused overwrite"
    fi
else
    if [ "$et_in" = "*" ]; then
        cgi_error "412 Precondition Failed" "If-Match: * refused create when absent"
    fi
    if [ -n "$et_in" ] && [ "$et_in" != "*" ]; then
        # Match a non-existent resource: always fail.
        cgi_error "412 Precondition Failed" "If-Match against missing resource"
    fi
    if [ "$none_match" = "*" ]; then
        # absent + If-None-Match: * -> create permitted.
        :
    fi
    if [ -n "$none_match" ] && [ "$none_match" != "*" ]; then
        # If-None-Match with a tag on a missing resource: also create.
        :
    fi
fi
if [ -n "${HTTP_IF_UNMODIFIED_SINCE:-}" ]; then
    mtime_epoch="$(stat -c '%Y' "$target" 2>/dev/null || true)"
    if ! dropbox_compare_if_unmodified_since "${HTTP_IF_UNMODIFIED_SINCE:-}" "${mtime_epoch:-}"; then
        cgi_error "412 Precondition Failed" "If-Unmodified-Since failed"
    fi
fi

mkdir -p "$(dirname -- "$target")"
chmod 0750 "$(dirname -- "$target")" 2>/dev/null || true

# Read the request body to a temp file under the box itself, atomic-rename
# into place. The temp name is constructed from the spec name + nanos so we
# do not collide with concurrent PUTs.
tmp="$(mktemp "${target}.put.XXXXXX" 2>/dev/null)" || {
    cgi_error "500 Internal Server Error" "mktemp failed"
}

# Read stdin to the tmp. We deliberately do not use 'cat >' which can be
# interrupted; a single full read into the tmp before rename keeps
# collisions bounded.
cat > "$tmp"
chmod 0640 "$tmp"
[ -e "$target" ] && rm -- "$target"
mv -f -- "$tmp" "$target"

# Metadata: content-type, friendly-name, etag.
mime="${CONTENT_TYPE:-application/octet-stream}"
# Default name: the resource's basename (sanitized).
name="$(basename -- "$target")"
dropbox_write_drop_meta "$target" "$mime" "$name" \
    || echo "dropbox_write_drop_meta soft-fail" >&2

# Emit response headers.
etag="$(dropbox_compute_etag "$target")"
mtime_epoch="$(stat -c '%Y' "$target")"
lastmod="$(dropbox_http_date "$mtime_epoch")"

if [ "${existed}" = 1 ]; then
    dropbox_emit_status "204" "$etag" "$lastmod"
    cgi_header "text/plain"
    echo "overwritten"
else
    dropbox_emit_status "201" "$etag" "$lastmod"
    cgi_header "text/plain"
    echo "created"
fi
