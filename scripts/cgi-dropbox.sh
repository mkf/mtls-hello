#!/bin/bash
# Shared CGI helpers for the per-host drop-box handlers.
# Sourced by handlers/drop.*.sh; not executed directly.
#
# Conventions:
#   - Helpers print results on stdout, errors on stderr.
#   - Helpers return 0 on success, 1 on bad input (caller decides whether
#     to log+continue, e.g. "header absent" for an optional conditional),
#     2 on hard failures (validator rejections, malformed CN/path) — the
#     caller should emit cgi_error and exit on 2.
#   - Path validation is *strict*: anything not anchored under
#     <data-dir>/drop/<cn>/ is refused.
#   - Storage metadata prefers filesystem xattrs (user.mime, user.name,
#     user.etag); falls back to a sibling .meta sidecar file when the
#     filesystem does not support xattrs.

# box_dir_resolves_to / Caller CN ----

# dropbox_caller_cn
#   Reads SSL_CLIENT_S_DN_CN (set by Apache mod_ssl via +ExportCertData).
#   Normalizes whitespace, then returns 2 if the CN is missing, > 128 chars,
#   or contains anything outside [A-Za-z0-9._-].
#   Prints the sanitized CN on stdout.
dropbox_caller_cn() {
    local cn
    cn="${SSL_CLIENT_S_DN_CN:-}"
    if [ -z "$cn" ]; then
        echo "dropbox_caller_cn: no SSL_CLIENT_S_DN_CN" >&2
        return 2
    fi
    cn="${cn// }"  # remove spaces (RFC 2253 subject may carry whitespace)
    if [ "${#cn}" -gt 128 ]; then
        echo "dropbox_caller_cn: CN too long (${#cn} > 128)" >&2
        return 2
    fi
    if [[ ! "$cn" =~ ^[A-Za-z0-9._-]+$ ]]; then
        echo "dropbox_caller_cn: CN has invalid characters: '$cn'" >&2
        return 2
    fi
    echo "$cn"
}

# dropbox_data_dir
#   Picks <data-dir> from MTLS_DATA_DIR, with a deterministic fallback for
#   static checking. The data-dir is where <cn>/ files live.
#   Prints the absolute path; returns 2 if unset.
dropbox_data_dir() {
    local d
    d="${MTLS_DATA_DIR:-}"
    if [ -z "$d" ]; then
        echo "dropbox_data_dir: MTLS_DATA_DIR unset" >&2
        return 2
    fi
    echo "$d"
}

# dropbox_box_dir <CN>
#   Prints (and lazily creates) the per-caller box directory.
#   Returns 2 if the CN fails validation.
dropbox_box_dir() {
    local cn="$1" dd
    dd="$(dropbox_data_dir)" || return 2
    [ -n "$cn" ] || { echo "dropbox_box_dir: empty CN" >&2; return 2; }
    local box="$dd/drop/$cn"
    if [ ! -d "$box" ]; then
        mkdir -p "$box" 2>&1 || { echo "dropbox_box_dir: mkdir failed: $box" >&2; return 2; }
    fi
    chmod 0750 "$box" 2>&1 || true  # advisory
    echo "$box"
}

# Path validation ----

# dropbox_validate_path <PATH_INFO>
#   URL-decodes the path, rejects empty / leading '/' / '..' / control bytes
#   / '\\' separators / unprintable bytes / '%XX' hex escapes that don't
#   decode to a clean ASCII byte. Prints the relative name on stdout
#   (without a leading '/'; empty string allowed, for collection requests).
#   Returns 2 on rejection.
dropbox_validate_path() {
    local raw="${1:-}"
    # 1. Trim leading slash, allow empty.
    raw="${raw#/}"
    # 2. Reject backslashes (Windows-style separators).
    if [[ "$raw" == *\\* ]]; then
        echo "dropbox_validate_path: backslash in path: '$raw'" >&2
        return 2
    fi
    # 3. URL-decode any remaining %XX; reject malformed sequences; reject
    #    decoded bytes < 0x20 or = 0x7F (control/unprintable). We do this
    #    with a single bash loop.
    local out="" i ch hex byte
    i=0
    while (( i < ${#raw} )); do
        ch="${raw:i:1}"
        if [ "$ch" = "%" ]; then
            hex="${raw:i+1:2}"
            if [[ ! "$hex" =~ ^[0-9A-Fa-f]{2}$ ]]; then
                echo "dropbox_validate_path: bad % escape: '%${hex}' in '$raw'" >&2
                return 2
            fi
            byte=$(( 16#${hex} ))
            if (( byte < 0x20 )); then
                echo "dropbox_validate_path: control byte in path: '%${hex}'" >&2
                return 2
            fi
            # printf '\xHH' would need %b; use chr().
            out+="$(printf '%b' "\\x${hex}")"
            i=$(( i + 3 ))
        else
            out+="$ch"
            i=$(( i + 1 ))
        fi
    done
    # 4. Split on '/'; reject '..' segments and empty segments.
    local seg
    local IFS='/'
    local segs
    segs=( $out )
    for seg in "${segs[@]}"; do
        if [ -z "$seg" ]; then
            echo "dropbox_validate_path: empty segment in '$raw'" >&2
            return 2
        fi
        if [ "$seg" = "." ] || [ "$seg" = ".." ]; then
            echo "dropbox_validate_path: '$seg' segment rejected" >&2
            return 2
        fi
        if [[ ! "$seg" =~ ^[A-Za-z0-9._~%@:+,=!-]+$ ]]; then
            # Conservative allowlist — name-restricted charset for filesystems
            # + URL-safe special chars.
            echo "dropbox_validate_path: illegal char in segment '$seg'" >&2
            return 2
        fi
    done
    # 5. Reject overly long names (> 200 per segment is generous).
    for seg in "${segs[@]}"; do
        if [ "${#seg}" -gt 200 ]; then
            echo "dropbox_validate_path: segment too long (${#seg})" >&2
            return 2
        fi
    done
    # 6. Print the joined relative path (no leading slash).
    echo "${segs[*]}"
}

# dropbox_resolve <CN> <RELATIVE>
#   Joins box + relative path, normalizes, and verifies the result lies
#   under the box's root (defense-in-depth against any odd symlink race).
#   Prints the absolute filesystem path. Returns 2 on path leak.
dropbox_resolve() {
    local cn="$1" rel="$2" box
    box="$(dropbox_box_dir "$cn")" || return 2
    local target="$box/$rel"
    local real_box real_target
    real_box="$(cd "$box" && pwd -P 2>/dev/null)" || {
        echo "dropbox_resolve: cannot canonicalize '$box'" >&2; return 2; }
    # Use cd + pwd -P to canonicalize; relative target is rejected because
    # box + rel is already an absolute path under box.
    real_target="$(cd "$(dirname "$target")" 2>/dev/null && pwd -P)/$(basename "$target")" || {
        echo "dropbox_resolve: cannot canonicalize '$target'" >&2; return 2; }
    case "$real_target" in
        "$real_box"/|"$real_box")            : ;;
        *) echo "dropbox_resolve: '$real_target' is outside '$real_box'" >&2; return 2 ;;
    esac
    echo "$real_target"
}

# ETag ----

# dropbox_compute_etag <FILE>
#   Compute SHA-256 of file contents, prefixed with 'sha256:'.
#   Returns 1 if file does not exist; 2 on read error.
dropbox_compute_etag() {
    local f="$1"
    [ -f "$f" ] || { echo "dropbox_compute_etag: no file '$f'" >&2; return 1; }
    local sha
    sha="$(sha256sum -- "$f" 2>/dev/null | awk '{print $1}')" || return 2
    if [ -z "$sha" ]; then
        echo "dropbox_compute_etag: empty sha for '$f'" >&2
        return 2
    fi
    echo "sha256:$sha"
}

# dropbox_read_cached_etag <FILE>
#   Reads xattr user.etag if present; if the cached etag matches the
#   current contents, prints it; otherwise recomputes, updates the cache
#   (when possible), and prints the new etag.
#   Falls back to recompute-without-cache when xattr unavailable.
dropbox_read_cached_etag() {
    local f="$1" cached current
    [ -f "$f" ] || { echo "dropbox_read_cached_etag: no file '$f'" >&2; return 1; }
    if _dropbox_have_xattr && [ -n "$(_dropbox_xget user.etag "$f" 2>/dev/null)" ]; then
        cached="$(_dropbox_xget user.etag "$f")"
    fi
    current="$(dropbox_compute_etag "$f")" || return 2
    if [ -n "$cached" ] && [ "$cached" = "$current" ]; then
        echo "$cached"
        return 0
    fi
    echo "$current"
    return 0
}

# dropbox_write_drop_meta <FILE> <MIME> <NAME>
#   Sets user.mime, user.name, user.etag xattrs (and recomputes etag if
#   the file is regular); falls back to a <file>.meta sidecar JSON when
#   xattrs are unavailable.
#   Returns 2 on hard failure; warning-on-fallback printed to stderr.
dropbox_write_drop_meta() {
    local f="$1" mime="$2" name="$3"
    [ -e "$f" ] || { echo "dropbox_write_drop_meta: no file '$f'" >&2; return 2; }
    local etag=""
    if [ -f "$f" ]; then
        etag="$(dropbox_compute_etag "$f")" || return 2
        if _dropbox_have_xattr; then
            _dropbox_xset user.etag "$etag" "$f" || {
                echo "dropbox_write_drop_meta: xattr user.etag failed; using sidecar" >&2
                _dropbox_write_sidecar_meta "$f" "$mime" "$name" "$etag"
                return 0
            }
            _dropbox_xset user.mime "$mime" "$f" || true
            _dropbox_xset user.name "$name" "$f" || true
            return 0
        else
            _dropbox_write_sidecar_meta "$f" "$mime" "$name" "$etag"
            return 0
        fi
    else
        # Directory metadata; etag is not meaningful.
        if _dropbox_have_xattr; then
            _dropbox_xset user.mime "$mime" "$f" || true
            _dropbox_xset user.name "$name" "$f" || true
        else
            _dropbox_write_sidecar_meta "$f" "$mime" "$name" ""
        fi
        return 0
    fi
}

# dropbox_read_drop_meta <FILE>
#   Emits one key=value line per known attribute (user.mime, user.name,
#   user.etag). Reads xattrs first; falls back to sidecar JSON.
#   Returns 1 if the file is missing.
dropbox_read_drop_meta() {
    local f="$1" mime="" name="" etag=""
    [ -e "$f" ] || { echo "dropbox_read_drop_meta: no file '$f'" >&2; return 1; }
    if _dropbox_have_xattr; then
        mime="$(_dropbox_xget user.mime "$f" 2>/dev/null || true)"
        name="$(_dropbox_xget user.name "$f" 2>/dev/null || true)"
        etag="$(_dropbox_xget user.etag "$f" 2>/dev/null || true)"
    fi
    if [ -z "$mime$name$etag" ] && [ -f "$f.meta" ]; then
        # Sidecar — small JSON-ish single-line { "user.mime":"..","user.name":"..","user.etag":".." }
        local sidecar
        sidecar="$(cat -- "$f.meta" 2>/dev/null || true)"
        # Reading the JSON with bash is overkill — extract via grep.
        mime="$(echo "$sidecar" | sed -n 's/.*"user\.mime":"\([^"]*\)".*/\1/p')"
        name="$(echo "$sidecar" | sed -n 's/.*"user\.name":"\([^"]*\)".*/\1/p')"
        etag="$(echo "$sidecar" | sed -n 's/.*"user\.etag":"\([^"]*\)".*/\1/p')"
    fi
    [ -n "$mime" ] && echo "user.mime=$mime"
    [ -n "$name" ] && echo "user.name=$name"
    [ -n "$etag" ] && echo "user.etag=$etag"
    return 0
}

# Conditional headers / Range ----

# dropbox_parse_if_match <If_Match_Value>
#   Accepts: "<etag>", "*", or empty (returns 0/empty).
#   If multiple tags (a list per RFC 7232) — pick the first one that is
#   either a sha256: ETag or wildcard.
#   Prints the tag (sha256:hex or '*') on stdout, or empty when absent.
#   Returns 0 always; presence-vs-absence is the caller's signal.
dropbox_parse_if_match() {
    local v="${1:-}"
    v="${v# }"; v="${v% }"
    if [ -z "$v" ]; then
        echo ""; return 0
    fi
    if [ "$v" = "*" ]; then
        echo "*"; return 0
    fi
    # Strip surrounding weak indicator W/ if present.
    local stripped="${v#W/}"
    # Look for sha256: pattern; if quoted, strip quotes.
    local tag
    tag="$(echo "$stripped" | sed -n 's/^"\(sha256:[0-9a-fA-F]*\)"$/\1/p')"
    if [ -n "$tag" ]; then
        echo "$tag"; return 0
    fi
    # Loose quoted — keep as-is but strip quotes.
    tag="$(echo "$stripped" | sed -n 's/^"\(.*\)"$/\1/p')"
    if [ -n "$tag" ]; then
        echo "$tag"; return 0
    fi
    echo "$stripped"
}

# dropbox_parse_range <Range_Header> <Size>
#   Parses a single byte-range RFC 7233 header. Prints "START END" on stdout
#   (inclusive ranges, naturally clamped to size), and returns 0.
#   Multi-range (comma-list) returns 1 with "multi" on stdout.
#   Malformed or absent header returns 1 with empty stdout.
#   Out-of-range request sets 'start > end' which is *neither* 1 nor
#   matched: caller maps "start > end (or start >= size)" to 416.
#   Empty header returns 1 (no range).
dropbox_parse_range() {
    local hdr="${1:-}" size="${2:-0}"
    if [ -z "$hdr" ]; then echo ""; return 1; fi
    if [ -z "$size" ]; then echo ""; return 1; fi
    # Strip 'bytes=' prefix, optional whitespace.
    hdr="${hdr#bytes=}"
    hdr="${hdr# }"; hdr="${hdr% }"
    if [[ "$hdr" == *,* ]]; then
        echo "multi"; return 1
    fi
    local start end
    if [[ "$hdr" =~ ^-([0-9]+)$ ]]; then
        # bytes=-N: last N bytes.
        start=$(( size - BASH_REMATCH[1] ))
        if (( start < 0 )); then start=0; fi
        end=$(( size - 1 ))
    elif [[ "$hdr" =~ ^([0-9]+)-$ ]]; then
        start=${BASH_REMATCH[1]}
        end=$(( size - 1 ))
    elif [[ "$hdr" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        start=${BASH_REMATCH[1]}
        end=${BASH_REMATCH[2]}
        if (( end >= size )); then end=$(( size - 1 )); fi
    else
        echo ""; return 1
    fi
    if (( start >= size )); then
        echo "out"; return 1
    fi
    if (( end < start )); then
        echo ""; return 1
    fi
    echo "$start $end"
}

# dropbox_compare_if_unmodified_since <header_value> <mtime_epoch>
#   Returns 0 if the mtime is at-or-before the HTTP-date, 1 otherwise (or
#   if the header is absent or unparseable, so a missing precondition is
#   effectively satisfied).
dropbox_compare_if_unmodified_since() {
    local hdr="${1:-}" mtime_epoch="${2:-}"
    if [ -z "$hdr" ]; then return 0; fi
    local hdr_epoch
    hdr_epoch="$(date -u -d "$hdr" +%s 2>/dev/null || true)"
    if [ -z "$hdr_epoch" ]; then return 0; fi
    if [ -z "$mtime_epoch" ]; then return 0; fi
    # Use the "less-or-equal" meaning of If-Unmodified-Since.
    if (( mtime_epoch <= hdr_epoch )); then return 0; fi
    return 1
}

# dropbox_compare_if_modified_since <header_value> <mtime_epoch>
#   Symmetric to the above for fetch-side caching.
dropbox_compare_if_modified_since() {
    local hdr="${1:-}" mtime_epoch="${2:-}"
    if [ -z "$hdr" ]; then return 1; fi
    local hdr_epoch
    hdr_epoch="$(date -u -d "$hdr" +%s 2>/dev/null || true)"
    if [ -z "$hdr_epoch" ]; then return 1; fi
    if [ -z "$mtime_epoch" ]; then return 1; fi
    # "Not modified" -> return 0 (was last <= hdr_epoch).
    if (( mtime_epoch <= hdr_epoch )); then return 0; fi
    return 1
}

# Headers / ETag emission ----

# dropbox_emit_status <code> <quoted_etag> <lastmod_http_date>
#   Emits the canonical Apache CGI status + ETag + Last-Modified headers
#   on stdout. Used by every handler.
#   Pass empty etag/lastmod when not applicable.
dropbox_emit_status() {
    local code="$1" etag="$2" lastmod="$3"
    echo "Status: $code"
    [ -n "$etag" ] && echo "ETag: \"$etag\""
    [ -n "$lastmod" ] && echo "Last-Modified: $lastmod"
}

# dropbox_http_date <mtime_epoch>
#   Convert an mtime (epoch seconds) into RFC 7231 IMF-fixdate.
dropbox_http_date() {
    local epoch="${1:-}"
    if [ -z "$epoch" ]; then echo ""; return 1; fi
    # date -u -d "@$epoch" '+%a, %d %b %Y %H:%M:%S GMT'
    # BSD-date compatibility: -d "@<n>".
    date -u -d "@$epoch" '+%a, %d %b %Y %H:%M:%S GMT' 2>/dev/null
}

# dropbox_now_http_date: HTTP-date of "now".
dropbox_now_http_date() {
    date -u '+%a, %d %b %Y %H:%M:%S GMT'
}

# Helpers (private to this module) ----

# xattr presence probe (cached across calls within one process).
_dropbox_have_xattr() {
    declare -F _dropbox_xattr_probed > /dev/null || {
        if command -v setfattr >/dev/null 2>&1 && command -v getfattr >/dev/null 2>&1; then
            _dropbox_xattr_probed() { return 0; }
        else
            _dropbox_xattr_probed() { return 1; }
        fi
    }
    if _dropbox_xattr_probed; then return 0; else return 1; fi
}

_dropbox_xget() {
    local key="$1" f="$2"
    getfattr -n "$key" --absolute-names "$f" 2>/dev/null | sed -n 's/^[^=]*="\(.*\)"$/\1/p'
}

_dropbox_xset() {
    local key="$1" val="$2" f="$3"
    setfattr -n "$key" -v "$val" "$f" 2>/dev/null
}

_dropbox_write_sidecar_meta() {
    local f="$1" mime="$2" name="$3" etag="$4"
    # Minimal hand-built JSON; can be hand-parsed by dropbox_read_drop_meta.
    local esc="" stripped
    stripped="${mime//\\/\\\\}"
    stripped="${stripped//\"/\\\"}"
    stripped="${stripped//$'\n'/ }"
    local esc_mime="$stripped"
    stripped="${name//\\/\\\\}"
    stripped="${stripped//\"/\\\"}"
    stripped="${stripped//$'\n'/ }"
    local esc_name="$stripped"
    stripped="${etag//\\/\\\\}"
    stripped="${stripped//\"/\\\"}"
    local esc_etag="$stripped"
    cat > "$f.meta" <<EOF || return 2
{"user.mime":"$esc_mime","user.name":"$esc_name","user.etag":"$esc_etag"}
EOF
}
