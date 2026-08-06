#!/usr/bin/env bats
# Unit tests for scripts/cgi-dropbox.sh helpers.

# Helper module is reusable; we source it.
setup() {
    TMPDIR_ROOT="$(mktemp -d -t mtls-dropbox-test-XXXXXX)"
    export TMPDIR_ROOT
    export MTLS_DATA_DIR="$TMPDIR_ROOT"
    # shellcheck source=scripts/cgi-dropbox.sh
    . scripts/cgi-dropbox.sh
}

teardown() {
    if [ -n "${TMPDIR_ROOT:-}" ] && [ -d "$TMPDIR_ROOT" ]; then
        # Safe-deletion: only files we know about.
        # The directory tree under TMPDIR_ROOT contains: drop/<cn>/...
        # (deposited by tests). Use the project's safe-cleanup helper.
        # shellcheck source=scripts/cleanup-common.sh
        . scripts/cleanup-common.sh
        # Top-down scan would be simpler, but we have to obey the no-rm-rf
        # rule: only remove what the test explicitly created via known paths.
        # Tests create inside drop/<cn>/<name>; remove there first.
        local cn_box
        if [ -d "$TMPDIR_ROOT/drop" ]; then
            while IFS= read -r -d '' cn_dir; do
                # Remove interior files (no rm -rf; plain rm + rmdir).
                local f
                local shopt_was
                shopt_was=$(shopt -p nullglob 2>&1 || true)
                shopt -s nullglob
                for f in "$cn_dir"/*; do
                    if [ -e "$f" ] || [ -L "$f" ]; then
                        rm -- "$f" 2>/dev/null || true
                    fi
                done
                eval "$shopt_was" 2>&1 || true
                [ -d "$cn_dir" ] && rmdir -- "$cn_dir" 2>/dev/null || true
            done < <(find "$TMPDIR_ROOT/drop" -mindepth 1 -maxdepth 1 -type d -print0)
            [ -d "$TMPDIR_ROOT/drop" ] && rmdir -- "$TMPDIR_ROOT/drop" 2>/dev/null || true
        fi
        [ -d "$TMPDIR_ROOT" ] && rmdir -- "$TMPDIR_ROOT" 2>/dev/null || true
    fi
    unset SSL_CLIENT_DN_CN MTLS_DATA_DIR TMPDIR_ROOT
}

# --- dropbox_caller_cn ------------------------------------------------

@test "dropbox_caller_cn accepts a normal hostname" {
    SSL_CLIENT_S_DN_CN="alice"
    run dropbox_caller_cn
    [ "$status" -eq 0 ]
    [ "$output" = "alice" ]
}

@test "dropbox_caller_cn accepts letters-digits-dot-dash" {
    SSL_CLIENT_S_DN_CN="host-42.example.com"
    run dropbox_caller_cn
    [ "$status" -eq 0 ]
    [ "$output" = "host-42.example.com" ]
}

@test "dropbox_caller_cn rejects missing env" {
    unset SSL_CLIENT_S_DN_CN
    run dropbox_caller_cn
    [ "$status" -eq 2 ]
}

@test "dropbox_caller_cn rejects pathname-traversal CN" {
    SSL_CLIENT_S_DN_CN="../../etc"
    run dropbox_caller_cn
    [ "$status" -eq 2 ]
}

@test "dropbox_caller_cn rejects semicolon" {
    SSL_CLIENT_S_DN_CN="evil;rm"
    run dropbox_caller_cn
    [ "$status" -eq 2 ]
}

@test "dropbox_caller_cn rejects CN longer than 128" {
    SSL_CLIENT_S_DN_CN="$(printf 'a%.0s' $(seq 1 129))"
    run dropbox_caller_cn
    [ "$status" -eq 2 ]
}

# --- dropbox_validate_path -------------------------------------------

@test "dropbox_validate_path accepts a flat name" {
    run dropbox_validate_path "notes.txt"
    [ "$status" -eq 0 ]
    [ "$output" = "notes.txt" ]
}

@test "dropbox_validate_path accepts nested names" {
    run dropbox_validate_path "archive/2026/note.txt"
    [ "$status" -eq 0 ]
    [ "$output" = "archive/2026/note.txt" ]
}

@test "dropbox_validate_path decodes %2E%2E to ..  which is then rejected" {
    run dropbox_validate_path "%2E%2E"
    [ "$status" -eq 2 ]
}

@test "dropbox_validate_path rejects .. segments" {
    run dropbox_validate_path "../etc/passwd"
    [ "$status" -eq 2 ]
}

@test "dropbox_validate_path rejects leading slash with .." {
    run dropbox_validate_path "/../"
    [ "$status" -eq 2 ]
}

@test "dropbox_validate_path rejects backslash" {
    run dropbox_validate_path "..\\\\etc"
    [ "$status" -eq 2 ]
}

@test "dropbox_validate_path rejects control bytes (\\x01)" {
    run dropbox_validate_path "%01"
    [ "$status" -eq 2 ]
}

@test "dropbox_validate_path rejects empty segments" {
    run dropbox_validate_path "archive//x.txt"
    [ "$status" -eq 2 ]
}

@test "dropbox_validate_path rejects bad % escape" {
    run dropbox_validate_path "%ZZ"
    [ "$status" -eq 2 ]
}

@test "dropbox_validate_path accepts the empty string for collection requests" {
    run dropbox_validate_path ""
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "dropbox_validate_path rejects ? in segment" {
    run dropbox_validate_path "a?b"
    [ "$status" -eq 2 ]
}

# --- dropbox_compute_etag --------------------------------------------

@test "dropbox_compute_etag: same contents -> same hash" {
    # shellcheck source=scripts/cleanup-common.sh
    . scripts/cleanup-common.sh
    mkdir -p "$MTLS_DATA_DIR/drop/alice"
    echo "Hello" > "$MTLS_DATA_DIR/drop/alice/x.txt"
    run dropbox_compute_etag "$MTLS_DATA_DIR/drop/alice/x.txt"
    [ "$status" -eq 0 ]
    expected_sha="$(printf 'Hello\n' | sha256sum | awk '{print $1}')"
    [ "$output" = "sha256:$expected_sha" ]
}

@test "dropbox_compute_etag: different contents -> different hash" {
    mkdir -p "$MTLS_DATA_DIR/drop/alice"
    echo "Hello" > "$MTLS_DATA_DIR/drop/alice/x1.txt"
    echo "Hellp" > "$MTLS_DATA_DIR/drop/alice/x2.txt"
    e1="$(dropbox_compute_etag "$MTLS_DATA_DIR/drop/alice/x1.txt")"
    e2="$(dropbox_compute_etag "$MTLS_DATA_DIR/drop/alice/x2.txt")"
    [ "$e1" != "$e2" ]
}

@test "dropbox_compute_etag: prefix sha256:, hex, length 64" {
    mkdir -p "$MTLS_DATA_DIR/drop/alice"
    echo "x" > "$MTLS_DATA_DIR/drop/alice/y.txt"
    run dropbox_compute_etag "$MTLS_DATA_DIR/drop/alice/y.txt"
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^sha256:[0-9a-f]{64}$ ]]
}

@test "dropbox_compute_etag returns 1 for missing file" {
    run dropbox_compute_etag "$MTLS_DATA_DIR/does/not/exist"
    [ "$status" -eq 1 ]
}

# --- dropbox_box_dir --------------------------------------------------

@test "dropbox_box_dir creates the dir with cn" {
    SSL_CLIENT_S_DN_CN="bob"
    run dropbox_box_dir "bob"
    [ "$status" -eq 0 ]
    [ -d "$MTLS_DATA_DIR/drop/bob" ]
}

@test "dropbox_box_dir leaves an existing dir in place" {
    SSL_CLIENT_S_DN_CN="eve"
    mkdir -p "$MTLS_DATA_DIR/drop/eve"
    echo "x" > "$MTLS_DATA_DIR/drop/eve/old.txt"
    run dropbox_box_dir "eve"
    [ "$status" -eq 0 ]
    [ -f "$MTLS_DATA_DIR/drop/eve/old.txt" ]  # not wiped
}

# --- dropbox_resolve --------------------------------------------------

@test "dropbox_resolve: a legal path stays inside the box" {
    box="$(dropbox_box_dir "alice")"
    mkdir -p "$box/inner"
    target="$(dropbox_resolve "alice" "inner/x.txt")"
    [ "$target" = "$box/inner/x.txt" ]
}

@test "dropbox_resolve: a leak attempt (cn=*) is rejected" {
    # We can't pass a CN with slashes (would be rejected by validator); but
    # an explicit symlink trick can still be attempted. Use ln -s alone.
    box="$(dropbox_box_dir "alice")"
    mkdir -p "$box"
    if [ -w /tmp ]; then
        ln -sfn /etc "$box/etc-link" 2>/dev/null || true
        if [ -L "$box/etc-link" ]; then
            run dropbox_resolve "alice" "etc-link"
            [ "$status" -eq 2 ]
        fi
    fi
    [ ! -e "$box/etc-link/leak-check" ]  # we never wrote through the symlink
}

# --- dropbox_parse_range ---------------------------------------------

@test "dropbox_parse_range accepts bytes=0-9" {
    run dropbox_parse_range "bytes=0-9" 100
    [ "$status" -eq 0 ]
    [ "$output" = "0 9" ]
}

@test "dropbox_parse_range accepts a bytes=N- open-ended" {
    run dropbox_parse_range "bytes=50-" 100
    [ "$status" -eq 0 ]
    [ "$output" = "50 99" ]
}

@test "dropbox_parse_range accepts bytes=-N suffix-only" {
    run dropbox_parse_range "bytes=-10" 100
    [ "$status" -eq 0 ]
    [ "$output" = "90 99" ]
}

@test "dropbox_parse_range refuses a multi-range header" {
    run dropbox_parse_range "bytes=0-9,10-19" 100
    [ "$status" -eq 1 ]
    [ "$output" = "multi" ]
}

@test "dropbox_parse_range refuses an out-of-range start" {
    run dropbox_parse_range "bytes=200-300" 100
    [ "$status" -eq 1 ]
    [ "$output" = "out" ]
}

@test "dropbox_parse_range refuses a malformed header" {
    run dropbox_parse_range "abc=0-9" 100
    [ "$status" -eq 1 ]
    [ "$output" = "" ]
}

@test "dropbox_parse_range refuses an empty header (full body)" {
    run dropbox_parse_range "" 100
    [ "$status" -eq 1 ]
    [ "$output" = "" ]
}

# --- dropbox_parse_if_match ------------------------------------------

@test "dropbox_parse_if_match accepts a quoted sha256: ETag" {
    run dropbox_parse_if_match '"sha256:abcdef"'
    [ "$status" -eq 0 ]
    [ "$output" = "sha256:abcdef" ]
}

@test "dropbox_parse_if_match accepts a wildcard" {
    run dropbox_parse_if_match '*'
    [ "$status" -eq 0 ]
    [ "$output" = "*" ]
}

@test "dropbox_parse_if_match returns empty for an empty header" {
    run dropbox_parse_if_match ""
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "dropbox_parse_if_match strips a W/ weak indicator" {
    run dropbox_parse_if_match 'W/"sha256:deadbeef"'
    [ "$status" -eq 0 ]
    [ "$output" = "sha256:deadbeef" ]
}

# --- dropbox_write_drop_meta / dropbox_read_drop_meta roundtrip ------

@test "drop_meta roundtrip (file mode)" {
    mkdir -p "$MTLS_DATA_DIR/drop/alice"
    echo "Hello" > "$MTLS_DATA_DIR/drop/alice/x.txt"
    run dropbox_write_drop_meta "$MTLS_DATA_DIR/drop/alice/x.txt" "text/plain" "x.txt"
    [ "$status" -eq 0 ]
    out="$(dropbox_read_drop_meta "$MTLS_DATA_DIR/drop/alice/x.txt")"
    [[ "$out" == *"user.mime=text/plain"* ]]
    [[ "$out" == *"user.name=x.txt"* ]]
    [[ "$out" == *"user.etag=sha256:"* ]]
}

# --- conditional date helpers ----------------------------------------

@test "dropbox_compare_if_modified_since: present mtime -> not modified" {
    run dropbox_compare_if_modified_since "Tue, 06 Aug 2030 00:00:00 GMT" "$(date -u -d '2026-08-06' +%s)"
    [ "$status" -eq 0 ]
}

@test "dropbox_compare_if_modified_since: future mtime -> modified" {
    run dropbox_compare_if_modified_since "Tue, 06 Aug 2026 00:00:00 GMT" "$(date -u +%s)"
    [ "$status" -eq 1 ]
}

@test "dropbox_compare_if_unmodified_since: future mtime -> fail" {
    # If the file is NEWER than the preconditioned cutoff, writes must
    # fail (cond 412).
    run dropbox_compare_if_unmodified_since "Tue, 06 Aug 2026 00:00:00 GMT" "$(date -u +%s)"
    [ "$status" -eq 1 ]
}

# --- dropbox_http_date ----------------------------------------------

@test "dropbox_http_date round-trips to RFC 7231 IMF-fixdate" {
    run dropbox_http_date 1754400000
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[A-Z][a-z]{2}, [ 0-9][0-9] [A-Z][a-z]{2} 2025 [0-9]{2}:[0-9]{2}:[0-9]{2} GMT$ ]]
}

# --- dropbox_emit_status ---------------------------------------------

@test "dropbox_emit_status emits status, etag, lastmod" {
    run dropbox_emit_status "200" "sha256:abc" "Tue, 06 Aug 2026 12:00:00 GMT"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "Status: 200" ]
    [ "${lines[1]}" = 'ETag: "sha256:abc"' ]
    [ "${lines[2]}" = "Last-Modified: Tue, 06 Aug 2026 12:00:00 GMT" ]
}

@test "dropbox_emit_status omits empty etag" {
    run dropbox_emit_status "204" "" ""
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "Status: 204" ]
}
